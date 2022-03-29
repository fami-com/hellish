with Ada.Text_Io; use Ada.Text_Io;
with Ada.Integer_Text_Io; use Ada.Integer_Text_Io;
with Ada.Float_Text_Io; use Ada.Float_Text_Io;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Strings.Maps.Constants; use Ada.Strings.Maps.Constants;
with Ada.Exceptions; use Ada.Exceptions;
with Ada.Directories;
with Ada.Containers.Indefinite_Holders;
with Ada.Calendar;

with GNAT.Regpat; use GNAT.Regpat;
with Gnat.SHA1;
with GNAT.Command_Line;
with GNAT.Traceback.Symbolic;

with Markdown; use Markdown;

with
  Aws.Cookie,
  Aws.Session,
  Aws.Server.Log,
  Aws.Config,
  Aws.Services.Dispatchers.Uri,
  AWS.Mime,
  Aws.Parameters,
  Aws.Messages,
  Aws.Headers,
  Aws.Resources,
  Aws.Resources.Streams.Memory,
  Aws.Translator,
  Aws.Response.Set,
  Aws.Log,
  Aws.Exceptions;

with
  Templates_Parser,
  Templates_Parser.Utils;
use Templates_Parser;

with Gnatcoll.Json;

with Hellish_Web.Bencoder;
with Hellish_Web.Peers;
with Hellish_Web.Database;

with Orm; use Orm;

package body Hellish_Web.Routes is
   Default_Md_Flags : Markdown.Parser_Flag := Md_Flag_No_Html_Blocks
     or Md_Flag_No_Html_Spans
     or Md_Flag_Permissive_Url_Autolinks
     or Md_Flag_Strikethrough;

   function To_Hex_string(Input : String) return String is
      Result : Unbounded_String;
   begin
      for Char of Input loop
         declare
            Hex_Prefix_Length : constant := 3;
            Hexa : String (1 .. Hex_Prefix_Length + 3 + 1);
            Temp : String (1 .. 2);
            Start : Natural;
         begin
            -- A ridiculously difficult way of translating a decimal into hex without 16# and #
            Put(Hexa, Character'Pos(Char), 16);
            Start := Ada.Strings.Fixed.Index(Source => Hexa, Pattern => "#");
            Ada.Strings.Fixed.Move(Source  => Hexa (Start + 1 .. Hexa'Last - 1),
                                   Target  => Temp,
                                   Justify => Ada.Strings.Right,
                                   Pad => '0');

            Append(Result, Trim(Temp, Ada.Strings.Both));
         end;
      end loop;
      -- Translate to lowercase to match what Transmission shows
      Translate(Result, Lower_Case_Map);

      return To_String(Result);
   end;

   function Request_Session(Request : Status.Data) return Session.Id is
   begin
      if Cookie.Exists(Request, Server.Session_Name) then
         return Session.Value(Cookie.Get(Request, Server.Session_Name));
      else
         return Status.Session(Request);
      end if;
   end Request_Session;

   function Decoded_Torrent(The_Torrent : Detached_Torrent'Class) return Bencoder.Bencode_Value_Holders.Holder is
      use Ada.Directories;
      use Bencoder;

      File_Path : String := Compose(Containing_Directory => Uploads_Path,
                                    Name => The_Torrent.Info_Hash,
                                    Extension => "torrent");
      File : File_Type;
      Decoded : Bencode_Value_Holders.Holder;
      Bencoded_Info : Bencode_Value_Holders.Holder;
   begin
      Open(File, Mode => In_File, Name => File_Path);
      Decoded := Decode(File);
      Close(File);

      return Decoded;
   end Decoded_Torrent;

   function Bytes_To_Printable(Bytes : Long_Long_Integer) return String is
      Float_Repr : Float;
      Unit : String (1..3);
      Formatted_Str : String (1 .. 16);
   begin
      if Bytes >= (1024 * 1024 * 1024) then
         Float_Repr := Float(Bytes) / 1024.0 / 1024.0 / 1024.0;
         Unit := "GiB";
      elsif Bytes >= (1024 * 1024) then
         Float_Repr := Float(Bytes) / 1024.0 / 1024.0;
         Unit := "MiB";
      elsif Bytes >= 1024 then
         Float_Repr := Float(Bytes) / 1024.0;
         Unit := "KiB";
      else
         Float_Repr := Float(Bytes);
         Unit := "B  ";
      end if;
      Put(Formatted_Str, Float_Repr, Aft => 2, Exp => 0);

      return Trim(Formatted_Str, Ada.Strings.Both) & Trim(Unit, Ada.Strings.Right);
   end Bytes_To_Printable;

   function User_Announce_Url(The_User : Detached_User'Class) return String is
     -- TODO: HTTPS
      ((if Https then "https://" else "http://") & Host & "/" & The_User.Passkey & "/announce");

   Announce_Passkey_Matcher : constant Pattern_Matcher := Compile("/(\w+)/announce");

   function Dispatch
     (Handler : in Announce_Handler;
      Request : in Status.Data) return Response.Data is
      Params : constant Parameters.List := AWS.Status.Parameters(Request);

      Result : Bencoder.Bencode_Value_Holders.Holder;

      Matches : Match_Array (0..1);
      Uri : String := Status.Uri(Request);

      User : Detached_User;
   begin
      Match(Announce_Passkey_Matcher, Uri, Matches);
      declare
         Match : Match_Location := Matches(1);
         Passkey : String := Uri(Match.First..Match.Last);
      begin
         User := Detached_User(Database.Get_User_By_Passkey(Passkey));

         if User = No_Detached_User then
            Result := Bencoder.With_Failure_Reason("Invalid passkey");
            goto Finish;
         end if;
      end;

      declare
         Required_Params : array (Natural range <>) of Unbounded_String :=
           (To_Unbounded_String("info_hash"), To_Unbounded_String("peer_id"),
            To_Unbounded_String("port"), To_Unbounded_String("uploaded"),
            To_Unbounded_String("downloaded"), To_Unbounded_String("left"));
         -- ip and event are optional
      begin
         for Name of Required_Params loop
            if not Params.Exist(To_String(Name)) then
               Result := Bencoder.With_Failure_Reason(To_String(Name & " is missing"));
               goto Finish;
            end if;
         end loop;
      end;

      declare
         Info_Hash : String := Params.Get("info_hash");
         Info_Hash_Hex : String := To_Hex_String(info_hash);
         Ip : Unbounded_String := To_Unbounded_String(if Params.Exist("ip")
                                                      then Params.Get("ip")
                                                      else Aws.Status.Peername(Request));
      begin
         if Detached_Torrent(Database.Get_Torrent_By_Hash(Info_Hash_Hex)) = No_Detached_Torrent then
            Result := Bencoder.With_Failure_Reason("Unregistered torrent");
            goto Finish;
         end if;

         if Params.Get("event") = "completed" then
            -- Increment the downloaded count
            Database.Snatch_Torrent(Info_Hash_Hex);
         end if;

         Peers.Protected_Map.Add(Info_Hash_Hex,
                                 (Peer_Id => To_Unbounded_String(Params.Get("peer_id")),
                                  Ip => Ip,
                                  Port => Positive'Value(Params.Get("port")),
                                  Uploaded => Long_Long_Integer'Value(Params.Get("uploaded")),
                                  Downloaded => Long_Long_Integer'Value(Params.Get("downloaded")),
                                  Left => Long_Long_Integer'Value(Params.Get("left"))),
                                 User);
         if Params.Get("event") = "stopped" then
               Peers.Protected_Map.Remove(To_Hex_String(info_hash), To_Unbounded_String(Params.Get("peer_id")));
         end if;

         declare
            Compact : Boolean := not Params.Exist("compact") or Params.Get("compact") = "1";
            Num_Want : Natural := 50;

            package Indefinite_String_Holders is new Ada.Containers.Indefinite_Holders(String);
            use Indefinite_String_Holders;

            Warning : Indefinite_String_Holders.Holder;
            procedure Include_Warning(Dict : in out Bencoder.Bencode_Value'Class) is
            begin
               -- Add the warning to the held result
               Bencoder.Bencode_Dict(Dict).Include("warning message", Bencoder.Encode(Warning.Element));
            end Include_Warning;
         begin
            if Params.Exist("numwant") then
               begin
                  Num_Want := Natural'Value(Params.Get("numwant"));
               exception
                  when Constraint_Error =>
                     -- Don't fail just because the number wasn't properly provided, just use the default
                     Warning := To_Holder("numwant was expected to be a positive number, but was " & Params.Get("numwant"));
               end;
            end if;

            Result :=
              Peers.Protected_Map.Encode_Hash_Peers_Response(Info_Hash_Hex, Params.Get("peer_id"),
                                                             (Compact => Compact, Num_Want => Num_Want));
            if not Warning.Is_Empty then
               Result.Update_Element(Include_Warning'Access);
            end if;
         end;
      end;

      -- Put_Line(Status.Parameters(Request).URI_Format);

      <<Finish>>
      return Response.Build(Mime.Text_Plain, Result.Element.Encoded);
   end Dispatch;

   function Dispatch
     (Handler : in Scrape_Handler;
      Request : in Status.Data) return Response.Data is
      Params : constant Parameters.List := AWS.Status.Parameters(Request);

      Info_Hashes : Parameters.VString_Array := Params.Get_Values("info_hash");

      Files : Bencoder.Bencode_Vectors.Vector;
      Result_Map : Bencoder.Bencode_Maps.Map;
   begin
      for Hash of Info_Hashes loop
         declare
            Info_Hash_Hex : String := To_Hex_String(To_String(Hash));
            Stats : Peers.Scrape_Stat_Data := Peers.Protected_Map.Scrape_Stats(Info_Hash_Hex);

            File_Stats : Bencoder.Bencode_Maps.Map;
         begin
            File_Stats.Include(To_Unbounded_String("complete"), Bencoder.Encode(Stats.Complete));
            File_Stats.Include(To_Unbounded_String("incomplete"), Bencoder.Encode(Stats.Incomplete));
            File_Stats.Include(To_Unbounded_String("downloaded"), Bencoder.Encode(Stats.Downloaded));

            Files.Append(Bencoder.Encode(File_Stats));
         end;
      end loop;
      Result_Map.Include(To_Unbounded_String("files"), Bencoder.Encode(Files));

      return Response.Build(Mime.Text_Plain, Bencoder.Encode(Result_Map).Element.Encoded);
   end Dispatch;

   function Dispatch
     (Handler : in Index_Handler;
      Request : in Status.Data) return Response.Data is
      Total_Stats : Peers.Total_Stats := Peers.Protected_Map.Total_Stat_Data;
      Translations : Translate_Set;

      Session_Id : Session.Id := Request_Session(Request);
      Username : String := Session.Get(Session_Id, "username");
   begin
      if not Database.User_Exists(Username) then
         return Response.Url(Location => "/login");
      end if;

      Insert(Translations, Assoc("current_seeders", Total_Stats.Seeders));
      Insert(Translations, Assoc("current_leechers", Total_Stats.Leechers));

      declare
         The_User : Detached_User'Class := Database.Get_User(Username);
      begin
         Insert(Translations, Assoc("uploaded", Bytes_To_Printable(The_User.Uploaded)));
         Insert(Translations, Assoc("downloaded", Bytes_To_printable(The_User.Downloaded)));

         Insert(Translations, Assoc("username", The_User.Username));
         Insert(Translations, Assoc("user_id", The_User.Id));
      end;

      declare
         Latest_News : Detached_Post'Class := Database.Get_Latest_News;
         News_Author : Detached_User'Class := No_Detached_User;
      begin
         if Latest_News /= Detached_Post'Class(No_Detached_Post) then
            News_Author := Database.Get_User(Latest_News.By_User);
            Insert(Translations, Assoc("news_id", Latest_News.Id));
            Insert(Translations, Assoc("news_title", Templates_Parser.Utils.Web_Escape(Latest_news.Title)));
            Insert(Translations, Assoc("news_content", Markdown.To_Html(Latest_News.Content, Default_Md_Flags)));
            Insert(Translations, Assoc("news_author", News_Author.Username));
            Insert(Translations, Assoc("news_author_id", News_author.Id));
         end if;
      end;

      return Response.Build(Mime.Text_Html,
                            String'(Templates_Parser.Parse("assets/index.html", Translations)));
   end Dispatch;

   function Dispatch
     (Handler : in Login_Handler;
      Request : in Status.Data) return Response.Data is
      Session_Id : Session.Id := Request_Session(Request);
      Username : String := Session.Get(Session_Id, "username");

      Params : constant Parameters.List := Status.Parameters(Request);
      Error_Param : String := Params.Get("error");
      Translations : Translate_Set;
   begin
      if Database.User_Exists(Username) then
         -- Redirect to the main page
         return Response.Url(Location => "/");
      end if;


      if Error_Param'Length > 0 then
         Insert(Translations, Assoc("error", Error_Param));
      end if;

      return Response.Build(Mime.Text_Html,
                            String'(Templates_Parser.Parse("assets/login.html", Translations)));
   end Dispatch;

   function Dispatch
     (Handler : in Register_Handler;
      Request : in Status.Data) return Response.Data is

      Session_Id : Session.Id := Request_Session(Request);
      Username : String := Session.Get(Session_Id, "username");

      Params : constant Parameters.List := Status.Parameters(Request);
      Error_Param : String := Params.Get("error");
      Translations : Translate_Set;
   begin
      if Database.User_Exists(Username) then
         -- Redirect to the main page
         return Response.Url(Location => "/");
      end if;
      if Error_Param'Length > 0 then
         Insert(Translations, Assoc("error", Error_Param));
      end if;

      return Response.Build(Mime.Text_Html,
                            String'(Templates_Parser.Parse("assets/register.html", Translations)));
   end Dispatch;

   Download_Id_Matcher : constant Pattern_Matcher := Compile("/download/(\d+)");
   function Dispatch
     (Handler : in Download_Handler;
      Request : in Status.Data) return Response.Data is

      Session_Id : Session.Id := Request_Session(Request);
      Username : String := Session.Get(Session_Id, "username");

      Matches : Match_Array (0..1);
      Uri : String := Status.Uri(Request);
   begin
      if not Database.User_Exists(Username) then
         -- Redirect to the login page
         return Response.Url(Location => "/login");
      end if;

      Match(Download_Id_Matcher, Uri, Matches);
      declare
         use Ada.Directories;
         use Bencoder;

         Match : Match_Location := Matches(1);
         Id : Natural := Natural'Value(Uri(Match.First..Match.Last));

         User : Detached_User'Class := Database.Get_User(Username);
         Torrent : Detached_Torrent'Class := Database.Get_Torrent(Id);

         File_Path : String := Compose(Containing_Directory => Uploads_Path,
                                       Name => Torrent.Info_Hash,
                                       Extension => "torrent");
         File : File_Type;
         Decoded : Bencode_Dict;
         Bencoded_Info : Bencode_Dict;

         File_Name : Unbounded_String;
      begin
         Open(File, Mode => In_File, Name => File_Path);
         Decoded := Bencode_Dict(Decode(File).Element);
         Close(File);

         Bencoded_Info := Bencode_Dict(Decoded.Value(To_Unbounded_String("info")).Element.Element);
         File_Name := Bencode_String(Bencoded_Info.Value(To_Unbounded_String("name")).Element.Element).Value;

         Decoded.Include("announce", Encode(User_Announce_Url(User)));

         declare
            use Aws.Resources.Streams.Memory;

            Data : not null access Resources.Streams.Memory.Stream_Type
              := new Resources.Streams.Memory.Stream_Type;

            Sent_Name : String := Compose(Name => Base_Name(To_String(File_Name)), Extension => "torrent");
         begin
            Append(Data.all,
                   Translator.To_Stream_Element_Array(To_String(Decoded.Encoded)),
                   Trim => False);

            return Response.Stream("application/x-bittorrent",
                                   Resources.Streams.Stream_Access(Data),
                                   Disposition => Response.Attachment,
                                   User_Filename => Sent_Name);
         end;
      end;
   end Dispatch;

   function Dispatch
     (Handler : in Upload_Handler;
      Request : in Status.Data) return Response.Data is

      Session_Id : Session.Id := Request_Session(Request);
      Username : String := Session.Get(Session_Id, "username");

      Translations : Translate_Set;

      Params : constant Parameters.List := Status.Parameters(Request);
      Update : String := Params.Get("update");
   begin
      if not Database.User_Exists(Username) then
         -- Redirect to the login page
         return Response.Url(Location => "/login");
      end if;
      declare
         User : Detached_User'Class := Database.Get_User(Username);
      begin
         Insert(Translations, Assoc("host", Host));
         Insert(Translations, Assoc("passkey", User.Passkey));
      end;
      if Update /= "" then
         declare
            The_Torrent : Detached_Torrent'Class := Database.Get_Torrent(Integer'Value(Update));
         begin
            Insert(Translations, Assoc("update", Update));
            Insert(Translations, Assoc("update_name", The_Torrent.Display_Name));
            Insert(Translations, Assoc("update_desc", The_Torrent.Description));
         end;
      else
         -- This needs to always be set, as textarea uses all whitespace literally
         -- and the template engine can't have anything else be on the same line as statements
         Insert(Translations, Assoc("update_desc", ""));
      end if;

      return Response.Build(Mime.Text_Html,
                            String'(Templates_Parser.Parse("assets/upload.html", Translations)));
   end Dispatch;

   View_Id_Matcher : constant Pattern_Matcher := Compile("/view/(\d+)");
   function Dispatch
     (Handler : in View_Handler;
      Request : in Status.Data) return Response.Data is

      Session_Id : Session.Id := Request_Session(Request);
      Username : String := Session.Get(Session_Id, "username");

      Matches : Match_Array (0..1);
      Uri : String := Status.Uri(Request);

      Params : constant Parameters.List := Status.Parameters(Request);
      Error : String := Params.Get("error");
   begin
      if not Database.User_Exists(Username) then
         -- Redirect to the login page
         return Response.Url(Location => "/login");
      end if;

      Match(View_Id_Matcher, Uri, Matches);
       declare
         use Bencoder;

         Match : Match_Location := Matches(1);
         Id : Natural := Natural'Value(Uri(Match.First..Match.Last));

         The_Torrent : Detached_Torrent'Class := Database.Get_Torrent(Id);
         Decoded : Bencode_Dict := Bencode_Dict(Decoded_Torrent(The_Torrent).Element);
         Bencoded_Info : Bencode_Dict := Bencode_Dict(Decoded.Value(To_Unbounded_String("info")).Element.Element);
         Uploader : Detached_User'Class := Database.Get_User(The_Torrent.Created_By);

         Original_File_Name : Unbounded_String;

         File_Names : Vector_Tag;
         File_Sizes : Vector_Tag;
         Total_Size : Long_Long_Integer := 0;
         Translations : Translate_Set;

         -- Escape whatever the user inputs as the name
         Html_Name : String := Templates_Parser.Utils.Web_Escape(The_Torrent.Display_Name);
         -- This both translates markdown to html and escapes whatever html the text might've had,
         -- so should be safe
         Html_Desc : String := Markdown.To_Html(The_Torrent.Description, Default_Md_Flags);

         The_User : Detached_User'Class := Database.Get_User(Username);
      begin
         Original_File_Name :=
           Bencode_String(Bencoded_Info.Value(To_Unbounded_String("name")).Element.Element).Value;

         Insert(Translations, Assoc("id", Id));
         Insert(Translations, Assoc("display_name", Html_Name));
         Insert(Translations, Assoc("description", Html_Desc));
         Insert(Translations, Assoc("original_name", Original_File_Name));
         Insert(Translations, Assoc("uploader", Uploader.Username));
         Insert(Translations, Assoc("uploader_id", Uploader.Id));
         Insert(Translations, Assoc("is_uploader", Uploader = The_user));

         if Bencoded_Info.Value.Contains(To_Unbounded_String("files")) then
            declare
               Files : Bencode_List :=
                 Bencode_List(Bencoded_Info.Value(To_Unbounded_String("files")).Element.Element);
            begin
               for Bencoded_File of Files.Value loop
                  declare
                     File : Bencode_Dict := Bencode_Dict(Bencoded_File.Element);
                     File_Path_List : Bencode_List := Bencode_List(File.Value(To_Unbounded_String("path")).Element.Element);

                     File_Path : Unbounded_String;
                     Size : Long_Long_Integer := Bencode_Integer(File.Value(To_Unbounded_String("length")).Element.Element).Value;
                  begin
                     for Path_Part of File_Path_List.Value loop
                        File_Path := File_Path & "/" & Bencode_String(Path_Part.Element).Value;
                     end loop;

                     -- Just in case the file name has something funny, escape it. It's user generated data after all.
                     File_Names := File_Names & Templates_Parser.Utils.Web_Escape(To_String(File_Path));
                     File_Sizes := File_Sizes & Bytes_To_Printable(size);
                     Total_Size := Total_Size + Size;
                  end;
               end loop;
            end;
         else
            declare
               Size : Long_Long_Integer := Bencode_Integer(Bencoded_Info.Value(To_Unbounded_String("length")).Element.Element).Value;
            begin
               File_Names := File_Names & ("/" & Original_File_Name);
               File_Sizes := File_Sizes & Bytes_To_Printable(Size);
               Total_Size := Size;
            end;
         end if;
         Insert(Translations, Assoc("file_name", File_Names));
         Insert(Translations, Assoc("file_size", File_Sizes));
         Insert(Translations, Assoc("total_size", Bytes_To_Printable(Total_Size)));

         declare
            Peer_Data : Peers.Scrape_Stat_data := Peers.Protected_Map.Scrape_Stats(The_Torrent.Info_Hash);
         begin
            Insert(Translations, Assoc("seeding", Peer_Data.Complete));
            Insert(Translations, Assoc("leeching", Peer_Data.Incomplete));
            Insert(Translations, Assoc("snatches", The_Torrent.Snatches));
         end;

         if Error /= "" then
            Insert(Translations, Assoc("error", Error));
         end if;

         return Response.Build(Mime.Text_Html,
                               String'(Templates_Parser.Parse("assets/view.html", Translations)));
      end;
   end Dispatch;

   overriding function Dispatch(Handler : in Invite_Handler;
                                Request : in Status.Data) return Response.Data is
      use Gnatcoll.Json;
      Result : Json_Value := Create_Object;

      Session_Id : Session.Id := Request_Session(Request);
      Username : String := Session.Get(Session_Id, "username");
   begin
      if not Database.User_Exists(Username) then
         -- Redirect to the login page
         return Response.Url(Location => "/login");
      end if;

      declare
         The_User : Detached_User'Class := Database.Get_User(Username);
         The_Invite : String := Database.Create_Invite(The_User);

         Invited_Users : Invite_List := Database.Get_Invited_Users(The_User);

         Translations : Translate_Set;
         Invited_User : Detached_User'Class := No_Detached_User;

         Invited_User_Names, Invited_User_Ul, Invited_User_Dl : Vector_Tag;
      begin
         Insert(Translations, Assoc("invite", The_Invite));

         while Invited_Users.Has_row loop
            Invited_User := Invited_Users.Element.For_User.Detach;

            Invited_User_Names := Invited_User_Names & Invited_User.Username;
            Invited_User_Ul := Invited_User_Ul & Bytes_To_Printable(Invited_User.Uploaded);
            Invited_User_Dl := Invited_User_Dl & Bytes_To_Printable(Invited_User.Downloaded);

            Invited_Users.Next;
         end loop;
         Insert(Translations, Assoc("invited_name", Invited_User_Names));
         Insert(Translations, Assoc("invited_uploaded", Invited_User_Ul));
         Insert(Translations, Assoc("invited_downloaded", Invited_User_Dl));

         return Response.Build(Mime.Text_Html,
                               String'(Templates_Parser.Parse("assets/invite.html", Translations)));
      end;
   end Dispatch;

   overriding function Dispatch(Handler : in Search_Handler;
                                Request : in Status.Data) return Response.Data is
      Session_Id : Session.Id := Request_Session(Request);
      Username : String := Session.Get(Session_Id, "username");

      Params : Parameters.List := Status.Parameters(Request);
      Query : String := Params.Get("query");
      Uploader : Natural := (if Params.Exist("uploader") then Natural'Value(Params.Get("uploader")) else 0);
      Page : Natural := (if Params.Exist("page") then Integer'Value(Params.Get("page")) else 1);

      Translations : Translate_Set;
   begin
      if not Database.User_Exists(Username) then
         -- Redirect to the login page
         return Response.Url(Location => "/login");
      end if;

      if Query /= "" then
         Insert(Translations, Assoc("query", Query));
      end if;
      if Uploader /= 0 then
         declare
            Uploader_User : Detached_User'Class := Database.Get_User(Uploader);
         begin
            if Detached_User(Uploader_User) /= No_Detached_User then
               Insert(Translations, Assoc("query_uploader", Uploader_User.Username));
            end if;
         end;
      end if;

      declare
         Page_Size : constant Natural := 25;
         Page_Offset : constant Natural := (Page - 1) * Page_Size;
         Total_Count : Natural;
         Found_Torrents : Torrent_List := Database.Search_Torrents(Query, Uploader, Page_Offset, Page_Size, Total_Count);
         -- Round up
         Page_Count : Natural := Natural(Float'Ceiling(Float(Total_Count) / Float(Page_Size)));

         Torrent_Names, Torrent_Ids,
           Torrent_Uploaders, Torrent_Uploader_Ids : Vector_Tag;
         Pages, Page_Addresses : Vector_Tag;
      begin
         while Found_Torrents.Has_Row loop
            Torrent_Ids := Torrent_Ids & Found_Torrents.Element.Id;
            Torrent_Names := Torrent_Names & Found_Torrents.Element.Display_Name;
            Torrent_Uploaders := Torrent_Uploaders & Database.Get_User(Found_Torrents.Element.Created_By).Username;
            Torrent_Uploader_Ids := Torrent_Uploader_Ids & Integer'(Found_Torrents.Element.Created_By);

            Found_Torrents.Next;
         end loop;

         Insert(Translations, Assoc("torrent_id", Torrent_Ids));
         Insert(Translations, Assoc("torrent_name", Torrent_Names));
         Insert(Translations, Assoc("torrent_uploader", Torrent_Uploaders));
         Insert(Translations, Assoc("torrent_uploader_id", Torrent_Uploader_Ids));

         if Page_Count > 1 then
            for P in 1..Page_Count loop
               if P <= 10 or P = Page_Count then
                  if P = Page_Count and Page_Count > 11 then
                     -- Insert a ... before the last page
                     Pages := Pages & "...";
                     Page_Addresses := Page_Addresses & "";
                  end if;

                  Pages := Pages & P;

                  Params.Update(To_Unbounded_String("page"),
                                To_Unbounded_String(Trim(P'Image, Ada.Strings.Left)),
                                Decode => False);
                  Page_Addresses := Page_Addresses & String'("/search" & Params.Uri_Format);
               end if;
            end loop;

            Insert(Translations, Assoc("page", Pages));
            Insert(Translations, Assoc("page_address", Page_Addresses));
         end if;

         return Response.Build(Mime.Text_Html,
                               String'(Templates_Parser.Parse("assets/search.html", Translations)));
      end;
   end Dispatch;

   Post_Id_Matcher : constant Pattern_Matcher := Compile("/post/(\d+)");
   function Dispatch
     (Handler : in Post_Handler;
      Request : in Status.Data) return Response.Data is

      Session_Id : Session.Id := Request_Session(Request);
      Username : String := Session.Get(Session_Id, "username");

      Matches : Match_Array (0..1);
      Uri : String := Status.Uri(Request);

      Page_Size : constant Natural := 25;
   begin
      if not Database.User_Exists(Username) then
         -- Redirect to the login page
         return Response.Url(Location => "/login");
      end if;

      Match(Post_Id_Matcher, Uri, Matches);
      declare
         Match : Match_Location := Matches(1);
         Id : Natural := Natural'Value(Uri(Match.First..Match.Last));

         Parent_Post : Detached_Post'Class := No_Detached_Post;
         Post : Detached_Post'Class := Database.Get_Post(Id, Parent_Post);
         Author : Detached_User'Class := Database.Get_User(Post.By_User);

         Translations : Translate_Set;
      begin
         if Parent_Post /= Detached_Post'Class(No_Detached_Post) then
            declare
               Total_Searched : Integer;
               -- -1 means all
               Searched_Replies : Post_List := Database.Post_Replies(Parent_Post.Id, 0, -1, Total_Searched);
               Searched_N : Natural := 0;

               Found_Page : Natural := 1;
            begin
               while Searched_Replies.Has_Row loop
                  Searched_N := Searched_N + 1;

                  if Searched_Replies.Element.Id = Post.Id then
                     Found_Page := Natural(Float'Ceiling(Float(Searched_N) / Float(Page_Size)));
                  end if;

                  Searched_Replies.Next;
               end loop;

               return Response.Url("/post/"
                                     & Trim(Parent_Post.Id'Image, Ada.Strings.Left)
                                     & "?page=" & Trim(Found_Page'Image, Ada.Strings.Left)
                                     & "#child-" & Trim(Post.Id'Image, Ada.Strings.Left));
            end;
         end if;
         declare
            Html_Title : String := Templates_Parser.Utils.Web_Escape(Post.Title);
            -- This both translates markdown to html and escapes whatever html the text might've had,
            -- so should be safe
            Post_Content : String := Markdown.To_Html(Post.Content, Default_Md_Flags);

            The_User : Detached_User'Class := Database.Get_User(Username);
         begin
            Insert(Translations, Assoc("id", Post.Id));
            Insert(Translations, Assoc("title", Html_Title));
            Insert(Translations, Assoc("content", Post_Content));
            Insert(Translations, Assoc("author", Author.Username));
            Insert(Translations, Assoc("author_id", Author.Id));
            Insert(Translations, Assoc("is_author", Author.Id = The_User.Id));

            declare
               Params : Parameters.List := Status.Parameters(Request);
               Page : Natural := (if Params.Exist("page") then Integer'Value(Params.Get("page")) else 1);

               Page_Offset : constant Natural := (Page - 1) * Page_Size;
               Total_Count : Natural;
               Replies : Post_List := Database.Post_Replies(Post.Id, Page_Offset, Page_Size, Total_Count);
               -- Round up
               Page_Count : Natural := Natural(Float'Ceiling(Float(Total_Count) / Float(Page_Size)));

               Reply : Orm.Post;
               Reply_Author : Detached_User'Class := No_Detached_User;
               Reply_Ids, Replies_Authors, Replies_Author_Ids, Replies_Content,
                 Replies_Is_Author : Vector_Tag;
               Pages, Page_Addresses : Vector_Tag;
            begin
               while Replies.Has_row loop
                  Reply := Replies.Element;
                  Reply_Author := Database.Get_User(Reply.By_User);

                  Reply_Ids := Reply_Ids & Reply.Id;
                  Replies_Authors := Replies_Authors & Reply_Author.Username;
                  Replies_Author_Ids := Replies_Author_Ids & Reply_Author.Id;
                  Replies_Content := Replies_Content & Markdown.To_Html(Reply.Content, Default_Md_Flags);
                  Replies_Is_Author := Replies_Is_Author & (Reply_Author.Id = The_User.Id);

                  Replies.Next;
               end loop;
               Insert(Translations, Assoc("reply_id", Reply_Ids));
               Insert(Translations, Assoc("reply_author", Replies_Authors));
               Insert(Translations, Assoc("reply_author_id", Replies_Author_Ids));
               Insert(Translations, Assoc("reply_content", Replies_Content));
               Insert(Translations, Assoc("reply_is_author", Replies_Is_Author));

               if Page_Count > 1 then
                  for P in 1..Page_Count loop
                     if P <= 10 or P = Page_Count then
                        if P = Page_Count and Page_Count > 11 then
                           -- Insert a ... before the last page
                           Pages := Pages & "...";
                           Page_Addresses := Page_Addresses & "";
                        end if;

                        Pages := Pages & P;

                        Params.Update(To_Unbounded_String("page"),
                                      To_Unbounded_String(Trim(P'Image, Ada.Strings.Left)),
                                      Decode => False);
                        Page_Addresses := Page_Addresses & String'(Status.Uri(Request) & Params.Uri_Format);
               end if;
            end loop;

            Insert(Translations, Assoc("page", Pages));
            Insert(Translations, Assoc("page_address", Page_Addresses));
         end if;
            end;

            return Response.Build(Mime.Text_Html,
                                  String'(Templates_Parser.Parse("assets/post.html", Translations)));
         end;
      end;
   end Dispatch;

   overriding function Dispatch(Handler : in Post_Create_Handler;
                                Request : in Status.Data) return Response.Data is
      Session_Id : Session.Id := Request_Session(Request);
      Username : String := Session.Get(Session_Id, "username");

      Translations : Translate_Set;
      The_User : Detached_User'Class := No_Detached_user;

      Params : Parameters.List := Status.Parameters(Request);
      Update : Natural := (if Params.Exist("update") then Natural'Value(Params.Get("update")) else 0);
   begin
      if not Database.User_Exists(Username) then
         -- Redirect to the login page
         return Response.Url(Location => "/login");
      end if;

      The_User := Database.Get_User(Username);
      Insert(Translations, Assoc("admin", The_User.Role = 1));

      Insert(Translations, Assoc("reply", False));
      Insert(Translations, Assoc("content", ""));
      if Update /= 0 then
         declare
            Parent_Post : Detached_Post'Class := No_Detached_Post;
            The_Post : Detached_Post'Class := Database.Get_Post(Update, Parent_Post);
         begin
            if Parent_Post /= Detached_Post'Class(No_Detached_Post) then
               Insert(Translations, Assoc("reply", True));
            end if;
            Insert(Translations, Assoc("update", Update));
            Insert(Translations, Assoc("title", The_Post.Title));
            Insert(Translations, Assoc("content", The_Post.Content));
            Insert(Translations, Assoc("flag", The_Post.Flag));
         end;
      end if;

      return Response.Build(Mime.Text_Html,
                               String'(Templates_Parser.Parse("assets/post_create.html", Translations)));
   end Dispatch;

   overriding function Dispatch(Handler : in Post_Search_Handler;
                                Request : in Status.Data) return Response.Data is
      Session_Id : Session.Id := Request_Session(Request);
      Username : String := Session.Get(Session_Id, "username");

      Params : Parameters.List := Status.Parameters(Request);
      Query : String := Params.Get("query");
      Uploader : Natural := (if Params.Exist("uploader") then Natural'Value(Params.Get("uploader")) else 0);
      Page : Natural := (if Params.Exist("page") then Integer'Value(Params.Get("page")) else 1);

      Translations : Translate_Set;
   begin
      if not Database.User_Exists(Username) then
         -- Redirect to the login page
         return Response.Url(Location => "/login");
      end if;

      if Query /= "" then
         Insert(Translations, Assoc("query", Query));
      end if;

      declare
         Page_Size : constant Natural := 25;
         Page_Offset : constant Natural := (Page - 1) * Page_Size;
         Total_Count : Natural;
         Found_Posts : Post_List := Database.Search_Posts(Query, Page_Offset, Page_Size, Total_Count);
         -- Round up
         Page_Count : Natural := Natural(Float'Ceiling(Float(Total_Count) / Float(Page_Size)));

         Post_Titles, Post_Ids,
           Post_Authors, Post_Author_Ids,
           Post_Flags : Vector_Tag;
         Pages, Page_Addresses : Vector_Tag;
      begin
         while Found_Posts.Has_Row loop
            Post_Ids := Post_Ids & Found_Posts.Element.Id;
            Post_Titles := Post_Titles & Found_Posts.Element.Title;
            Post_Authors := Post_Authors & Database.Get_User(Found_Posts.Element.By_User).Username;
            Post_Author_Ids := Post_Author_Ids & Integer'(Found_Posts.Element.By_User);
            if Found_Posts.Element.Flag = 1 then
               Post_Flags := Post_Flags & "News";
            else
               Post_Flags := Post_Flags & "";
            end if;

            Found_Posts.Next;
         end loop;

         Insert(Translations, Assoc("post_id", Post_Ids));
         Insert(Translations, Assoc("post_title", Post_Titles));
         Insert(Translations, Assoc("post_author", Post_Authors));
         Insert(Translations, Assoc("post_author_id", Post_Author_Ids));
         Insert(Translations, Assoc("post_flag", Post_Flags));

         if Page_Count > 1 then
            for P in 1..Page_Count loop
               if P <= 10 or P = Page_Count then
                  if P = Page_Count and Page_Count > 11 then
                     -- Insert a ... before the last page
                     Pages := Pages & "...";
                     Page_Addresses := Page_Addresses & "";
                  end if;

                  Pages := Pages & P;

                  Params.Update(To_Unbounded_String("page"),
                                To_Unbounded_String(Trim(P'Image, Ada.Strings.Left)),
                                Decode => False);
                  Page_Addresses := Page_Addresses & String'("/post/search" & Params.Uri_Format);
               end if;
            end loop;

            Insert(Translations, Assoc("page", Pages));
            Insert(Translations, Assoc("page_address", Page_Addresses));
         end if;

         return Response.Build(Mime.Text_Html,
                               String'(Templates_Parser.Parse("assets/post_search.html", Translations)));
      end;
   end Dispatch;

   -- API

   function Dispatch
     (Handler : in Api_Upload_Handler;
      Request : in Status.Data) return Response.Data is
      use Ada.Directories;
      use Orm;

      Params : constant Parameters.List := Status.Parameters(Request);

      File_Path : String := Params.Get("file");
      Display_Name : String := Params.Get("name");
      Description : String := Params.Get("description");
      Update : String := Params.Get("update");

      Session_Id : Session.Id := Request_Session(Request);
      Username : String := Session.Get(Session_Id, "username");

      procedure Set_Updatable_Fields_And_Create(The_Torrent : in out Detached_Torrent'class) is
      begin
         The_Torrent.Set_Display_Name(Display_Name);
         The_Torrent.Set_Description(Description);
         Database.Create_Torrent(The_Torrent);
      end Set_Updatable_Fields_And_Create;
   begin
      if not Database.User_Exists(Username) then
         return Response.Acknowledge(Messages.S403, "Forbidden");
      end if;

      if Update /= "" then
         declare
            Update_Id : Integer := Integer'Value(Update);
            The_Torrent : Detached_Torrent'Class := Database.Get_Torrent(Update_Id);
            The_User : Detached_User'Class := Database.Get_User(Username);
         begin
            -- Only the creator can update the torrent
            if Integer'(The_Torrent.Created_By) /= The_User.Id then
               return Response.Acknowledge(Messages.S403, "Forbidden");
            end if;

            Set_Updatable_Fields_And_Create(The_Torrent);

            return Response.Url("/view/" & Update);
         end;
      end if;

      declare
         use Bencoder;
         File : File_Type;

         Decoded : Bencode_Dict;
         Decoded_Info : Bencode_Dict;

         Error_String : Unbounded_String;
      begin
         Open(File, Mode => In_File, Name => File_Path);
         Decoded := Bencode_Dict(Decode(File).Element);
         Close(File);

         Decoded_Info := Bencode_Dict(Decoded.Value(To_Unbounded_String("info")).Element.Element);

         if Bencode_Integer(Decoded_Info.Value(To_Unbounded_String("private")).Element.Element).Value /= 1 then
            Decoded_Info.Include("private", Encode(Natural'(1)));
            Decoded.Include("info", Bencode_Value_Holders.To_Holder(Decoded_Info));
            Error_String := To_Unbounded_String("The torrent wasn't set as private, you have to redownload it from this page for it to work.");
         end if;

         declare
            Bencoded_Info : Unbounded_String := Decoded_Info.Encoded;
            Sha1_Hash : String := Gnat.Sha1.Digest(To_String(Bencoded_Info));
            New_Name : String := Compose(Name => Sha1_Hash, Extension => "torrent");
            Uploaded_Path : String := Compose(Containing_Directory => Uploads_Path,Name => New_Name);

            Created_By : Detached_User'Class := Database.Get_User(Username);
            Maybe_Existing : Detached_Torrent'Class := Database.Get_Torrent_By_Hash(Sha1_Hash);
            The_Torrent : Detached_Torrent'Class := New_Torrent;

            Created_File : File_Type;
         begin
            if Detached_Torrent(Maybe_Existing) /= No_Detached_Torrent then
               return Response.Url("/upload?error=Torrent with this hash already exists&existing_id="
                                     & Trim(Maybe_Existing.Id'Image, Ada.Strings.Left));
            end if;

            Create_Path(Uploads_Path);

            Create(Created_File, Mode => Out_File, Name => Uploaded_Path);
            Put(Created_File, To_String(Decoded.Encoded));
            Close(Created_File);


            -- Only really need to save the hash, since it's the filename. Things like actual file name and such
            -- are encoded in the torrent file itself.
            -- The fields mentioned here explicitly can't be updated
            The_Torrent.Set_Info_Hash(Sha1_Hash);
            The_Torrent.Set_Created_By(Created_By);
            The_Torrent.Set_Snatches(0);
            Set_Updatable_Fields_And_Create(The_Torrent);

            if Error_String = "" then
               return Response.Url("/view/" & Trim(The_Torrent.Id'Image, Ada.Strings.Left));
            else
               return Response.Url("/view/" & Trim(The_Torrent.Id'Image, Ada.Strings.Left) & "?error=" & To_String(Error_String));
            end if;
         end;
      end;
   end Dispatch;

   function Dispatch(Handler : in Api_User_Register_Handler;
                     Request : in Status.Data) return Response.Data is
      Params : constant Parameters.List := Status.Parameters(Request);
      Username : String := Params.Get("username");
      Password : String := Params.Get("password");
      Invite : String := Params.Get("invite");

      Min_Name_Length : constant Positive := 1;
      Min_Pwd_Length : constant Positive := 8;

      package Indefinite_String_Holders is new Ada.Containers.Indefinite_Holders(String);
      use Indefinite_String_Holders;

      Error_String : Indefinite_String_Holders.Holder;
   begin
      if Username'Length < Min_Name_Length then
         Error_String := To_Holder("Username must be at least" & Min_Name_Length'Image & " characters long");

         goto Finish;
      end if;
      if Password'Length < Min_Pwd_Length then
         Error_String := To_Holder("Password must be at least" & Min_Pwd_Length'Image & " characters long");

         goto Finish;
      end if;
      if Invite_Required and then not Database.Invite_Valid(Invite) then
         Error_String := To_Holder("Invalid invite");

         goto Finish;
      end if;

      declare
         New_User : Detached_User'Class := No_Detached_User;
         Created : Boolean := Database.Create_User(Username, Password, New_User);
      begin
         if not Created then
            Error_String := To_Holder("Username already taken");

            goto Finish;
         end if;

         if Invite_Required then
            Database.Invite_Use(Invite, New_User);
         end if;
      end;

   <<Finish>>
      if Error_String.Is_Empty then
         declare
            -- Always associate a new session with the request on login,
            -- doesn't seem to work well otherwise
            Session_Id : Session.ID := Status.Session(Request);
         begin
            Session.Set(Session_Id, "username", Username);
            Session.Save(Session_File_Name);

            return Response.Url(Location => "/login");
         end;
      else
         return Response.Url(Location => "/register?error=" & Error_String.Element);
      end if;
   end Dispatch;

   overriding function Dispatch(Handler : in Api_User_Login_Handler;
                                Request : in Status.Data) return Response.Data is
      Params : constant Parameters.List := Status.Parameters(Request);
      Username : String := Params.Get("username");
      Password : String := Params.Get("password");

      Success : Boolean := Database.Verify_User_Credentials(Username, Password);

      -- Always associate a new session with the request on login,
      -- doesn't seem to work well otherwise
      Session_Id : Session.ID := Status.Session(Request);
   begin
      if Success then
         declare
            User : Detached_User'Class := Database.Get_User(Username);
         begin
            Session.Set(Session_Id, "username", User.Username);
            Session.Save(Session_File_Name);

            -- Redirect to login page
            return Response.Url(Location => "/");
         end;
      else
         return Response.Url(Location => "/login?error=Invalid username or password");
      end if;
   end Dispatch;

   overriding function Dispatch(Handler : in Api_User_Logout_Handler;
                                Request : in Status.Data) return Response.Data is
      Session_Id : Session.Id := Request_Session(Request);
      Result : Response.Data := Response.Url("/login");
   begin
      Session.Delete(Session_Id);
      Session.Save(Session_File_Name);

      Response.Set.Add_Header(Result, "Set-Cookie", AWS.Server.Session_Name & "=; Path=/");

      return Result;
   end Dispatch;

   overriding function Dispatch(Handler : in Api_Post_Create_Handler;
                                Request : in Status.Data) return Response.Data is
      Session_Id : Session.Id := Request_Session(Request);
      Username : String := Session.Get(Session_Id, "username");
      The_User : Detached_User'Class := No_Detached_User;

      Params : constant Parameters.List := Status.Parameters(Request);
      Title : String := Params.Get("title");
      Content : String := Params.Get("content");
      Parent : Integer := (if Params.Exist("parent") then Natural'Value(Params.Get("parent")) else -1);
      Flag : Integer := (if Params.Exist("flag") then Natural'Value(Params.Get("flag")) else 0);

      Update : Integer := (if Params.Exist("update") then Natural'Value(Params.Get("update")) else -1);
      Updated_Post : Detached_Post'Class := No_Detached_Post;

      Parent_Post : Detached_Post'Class := No_Detached_Post;
      Post : Detached_Post'Class := New_Post;
   begin
      if not Database.User_Exists(Username) then
         return Response.Acknowledge(Messages.S403, "Forbidden");
      end if;
      The_User := Database.Get_User(Username);

      if Update /= -1 then
         Updated_Post := Database.Get_Post(Update, Parent_Post);
         if Integer'(Updated_Post.By_User) /= The_User.Id then
            return Response.Acknowledge(Messages.S403, "Forbidden");
         end if;
         Post := Updated_Post;
      end if;

      Post.Set_By_User(The_User.Id);
      Post.Set_Content(Content);

      if Title /= "" then
         Post.Set_Title(Title);
      end if;
      if Parent /= -1 then
         Post.Set_Parent_Post(Parent);
      end if;
      if Flag = 1 and The_User.Role = 1 then
         Post.Set_Flag(Flag);
      end if;

      Database.Create_Post(Post);

      return Response.Url("/post/" & Trim(Post.Id'Image, Ada.Strings.Left));
   end Dispatch;

   -- Entrypoint

   procedure Exception_Handler(E : Exception_Occurrence;
                               Log    : in out Aws.Log.Object;
                               Error  : Aws.Exceptions.Data;
                               Answer : in out Response.Data) is
      Response_Html : String := "<!DOCTYPE HTML><body>" &
        "<b>" & Exception_Name(E) & "</b>" &
        "<pre>" & Exception_Information(E) & "</pre>" &
        "<pre>" & GNAT.Traceback.Symbolic.Symbolic_Traceback(E) & "</pre></body>";
   begin
      Answer := Response.Build(Mime.Text_Html, Response_Html);
   end Exception_Handler;

   procedure Run_Server is
      use GNAT.Command_Line;
   begin
      Server.Set_Unexpected_Exception_Handler(Http, Exception_Handler'Access);

      case Getopt("-invite-not-required") is
         when '-' =>
            if Full_Switch = "-invite-not-required" then
               Invite_Required := False;
            elsif Full_Switch = "-https" then
               Https := True;
            end if;
         when others => null;
      end case;

      Database.Init;

      if Ada.Directories.Exists(Session_File_Name) then
         Session.Load(Session_File_Name);
      end if;

      Services.Dispatchers.Uri.Register(Root, "/", Index);
      Services.Dispatchers.Uri.Register(Root, "/login", Login);
      Services.Dispatchers.Uri.Register(Root, "/register", Register);
      Services.Dispatchers.Uri.Register_Regexp(Root, "/(\w+)/announce", Announce);
      Services.Dispatchers.Uri.Register_Regexp(Root, "/(\w+)/scrape", Scrape);
      Services.Dispatchers.Uri.Register_Regexp(Root, "/download/(\d+)", Download);
      Services.Dispatchers.Uri.Register(Root, "/upload", Upload);
      Services.Dispatchers.Uri.Register_Regexp(Root, "/view/(\d+)", View);
      Services.Dispatchers.Uri.Register(Root, "/invite", Invite);
      Services.Dispatchers.Uri.Register(Root, "/search", Search);
      Services.Dispatchers.Uri.Register(Root, "/post/create", Post_Create);
      Services.Dispatchers.Uri.Register(Root, "/post/search", Post_Search);
      Services.Dispatchers.Uri.Register_Regexp(Root, "/post/(\d+)", Post);

      Services.Dispatchers.Uri.Register(Root, "/api/user/register", Api_User_Register);
      Services.Dispatchers.Uri.Register(Root, "/api/user/login", Api_User_Login);
      Services.Dispatchers.Uri.Register(Root, "/api/user/logout", Api_User_Logout);
      Services.Dispatchers.Uri.Register(Root, "/api/upload", Api_Upload);
      Services.Dispatchers.Uri.Register(Root, "/api/post/create", Api_Post_Create);

      Server.Start(Hellish_Web.Routes.Http, Root, Conf);
      Server.Log.Start(Http, Put_Line'Access, "hellish");

      Put_Line("Started on http://" & Aws.Config.Server_Host(Conf)
                 -- Trim the number string on the left because it has a space for some reason
                 & ":" & Trim(Aws.Config.Server_Port(Conf)'Image, Ada.Strings.Left));
      Server.Wait(Server.Q_Key_Pressed);

      Server.Shutdown(Http);
   end Run_Server;
end Hellish_Web.Routes;
