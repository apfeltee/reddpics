#!/usr/bin/ruby

require "fileutils"
require "uri"
require "uri/http"
require "http"
require "redd"
require "nokogiri"
require "trollop"
require "colorize"
require "filesize"

APIHELPSTRING = %q{
First, login to your account.
Then, to get your own API key, first visit https://www.reddit.com/prefs/apps - scroll down, and
click "Create app" (or "Create another app", if you have allowed an app to access your credentials).

In the formular that has presented itself before you, fill out the fields as follows:
  'name': Technically, you could write whatever in this field, but 'reddpics' seems like a solid choice.
  'description': give your API credentials a description. How about 'for use with reddpics'?
  'about url': Not used by reddpics, but you still need to enter something; try 'http://localhost/'. 
  'redirect uri': Some kind of URL. Something like 'http://localhost/' will work - it's not used anyway.
  select 'script' of the three choices - otherwise it won't work!

Note that none of 'name', 'description' or 'redirect uri' are ever used by reddpics! Nevertheless,
reddit insists that you enter something halfway meaningful.

Now that you've created the API credentials, you need to copy the information! This step is very easy, but
read carefully anyway:
- Your client ID is right below the string "personal use script" of the box bearing the name you've just given
  it moments earlier. You'll need that one!
- The API "key" is labelled with the string "secret" - you'll need that one as well.

If you run some kind of UNIX-ish operating system, such as Linux, Mac OSX, or Cygwin (http://cygwin.com), you
can store the API information as environment variables:
- Create a file named "reddit-api.sh" in ~/.config/ (create this directory if it doesn't exist)
- enter your API information like this and then save the file:
    export REDDPICS_APPID="<the-client-id>"
    export REDDPICS_APIKEY="<the-client-secret>"
    export REDDPICS_USERNAME="<your-reddit-username>"
    export REDDPICS_PASSWORD="<your-reddit-password>"
- add 'source ~/.config/reddit-api.sh' in your ~/.bashrc file (which is probably something else for zsh)
- enter 'exec bash' to reload your shell session
- Done! Now you don't have to manually enter your API credentials everytime you use reddpics.

Technically, you could also do this on windows:
Right-click on "This PC" on your desktop, click "Advanced system settings", go to the tab "Advanced", click
on "Environment Variables", and in the field "User variables for <your-username>", enter the variables
like REDDPICS_APIKEY, etc, in the usual fashion.

And that's it! Sounds complicated, but it really isn't. Really!
}.strip

# exceptions
class NoAdapterError < StandardError
end

# shitty logger
class Logger
  @indent = 0

  def self.putindent
    if @indent < 0 then
      @indent = 0
    end
    $stderr << ("  " * @indent)
  end

  def self.putprefix
    $stderr << "-- "
  end

  def self.putline(str=nil)
    putindent
    putprefix
    $stderr.puts(str)
  end

  def self.put(str)
    putindent
    putprefix
    $stderr << str
  end

  def self.write(str)
    $stderr << str
  end

  class << self
    attr_accessor :indent
  end
end

module Util
  def self.download(url, headers: {}, maxredirs: 5)
    Logger.put "wget(#{url.dump}) ... "
    begin
      response = HTTP.headers(headers).get(url)
      location = response["Location"]
      if response.code >= 400 then
        Logger.write "failed: HTTP status #{response.code} #{response.reason}\n".red
        return nil
      elsif location then
        if location.match(/^https?:/) then
          # this literally shouldn't have to be here, but because imgur is dumb, we have to.
          if not location.match(/imgur.com\/removed/) then
            if maxredirs == 0 then
              Logger.write "failed: too many redirects!\n".red
              return nil
            end
            $stderr << "redirect: #{location.dump}\n".yellow
            return download(location, headers: headers, maxredirs: maxredirs - 1)
          else
            Logger.write "failed: image has been removed (imgur hackery)\n".red
            return nil
          end
        else
          parts = URI.parse(url)
          relativedest = location
          if relativedest[0] == "/" then
            parts.path = relativedest
          else
            # the "directory" name being joined as a "file". abusing standard yey
            dirname = File.dirname(parts.path)
            parts.path = File.join(dirname, relativedest)
          end
          Logger.write "reconstructed relative redirect #{relativedest.dump} to #{parts.to_s.dump}\n".yellow
          return download(parts.to_s, headers: headers, maxredirs: maxredirs - 1)
        end
      end
      Logger.write "ok\n".green
      return response
    rescue => err
      Logger.write "failed: (#{err.class}) #{err.message}\n".red
      return nil
    end
  end

  # for reasons i cannot comprehend, URI::HTTP.build doesn't support a scheme option
  # can't make that shit up even if i tried
  def self.build_uri(opts)
    uri = URI::HTTP.build(opts)
    if opts[:scheme] then
      uri.scheme = opts[:scheme]
    end
    return uri.to_s
  end
end

module Adapters
  # disgusting hack incoming
  def self.imgurdl(url, response)
    parts = URI.parse(url)
    result = {name: nil, title: "", images: []}
    title = nil
    # further check if it's actually something extractable
    if not parts.host.match(/^((i|m)\.imgur|imgur|www\.imgur)\.com$/) then
      raise ArgumentError, "url #{url.dump} does not look like an imgur url"
    elsif (not parts.path) || (parts.path == "/") then
      raise ArgumentError, "can't download the entire frontpage. sorry :<"
    end
    # user favorites are almost guaranteed to fail.
    # don't be mad at me, be mad at imgur for their shitty API
    if parts.path.match("^/a/") then
      result[:name] = parts.path.split("/")[-1]
      source = "http://imgur.com/ajaxalbums/getimages/#{result[:name]}/hit.json"
      response = Util::download(source)
      if not response then
        raise ArgumentError, "could not download json information (#{source.dump})"
      end
      json = JSON.load(response.to_s)
      # how not to write an api: json.success returns true even if json.data is empty
      if (json["success"] == true) && (json["data"] != []) then
        json["data"]["images"].each do |imgchunk|
          finalurl = "http://i.imgur.com/#{imgchunk["hash"]}#{imgchunk["ext"]}"
          result[:images] << {url: finalurl, title: imgchunk["title"], description: imgchunk["description"]}
        end
      else
        if json["success"] != true then
          raise ArgumentError, "json was successfully downloaded and parsed, but key 'success' is false?"
        else
          raise ArgumentError, "key 'data' is just an empty array; probably not an album ..."
        end
      end
    else
      result[:name] = parts.path.split("/")[-1]
      document = Nokogiri::HTML(response.to_s)
      # this fails *very* often, so best to avoid it for now
      #result[:title] = document.css(".post-title").first
      document.css(".post-image-container>div").each do |node|
        # need to do sub-selection, because some images are wrapped in <a> for zooming
        img = node.css("img").first
        if img && img.attributes && img.attributes["src"] then
          srcattrib = img.attributes["src"]
          if srcattrib then
            url = srcattrib.value
            if url.start_with?("//") then
              url = "http:" + url
            end
            result[:images] << {url: url, title: "", description: ""}
          end
        end
      end
    end
    return result
  end

  # can't just do https://zippy.gfycat.com/... because gfycat may host webms on different hosts
  def self.gfycatdl(url, response)
    parts = URI.parse(url)
    info = {name: nil, images: []}
    info[:name] = parts.path.split("/")[1]
    apiurl = Util::build_uri({scheme: "https", host: "gfycat.com", path: File.join("/cajax/get", info[:name])})
    apiresponse = Util::download(apiurl.to_s)
    if apiresponse then
      json = JSON.parse(apiresponse.to_s)
      gfyitem = json["gfyItem"]
      info[:images] << {url: gfyitem["webmUrl"], title: gfyitem["redditIdText"], description: ""}
      return info
    else
      raise ArgumentError, "gfycat api call failed!"
    end
  end

  # attempt to avoid redirects (in an extremely primitive way)
  def self.fixurl(url)
    parts = URI.parse(url)
    if parts.host.match(/^(www\.)?gfycat.com/) then
      parts.scheme = "https"
      if parts.host == "www.gfycat.com" then
        parts.host = "gfycat.com"
      end
      return parts.to_s
    end
    return url
  end

  def self.tryparse(url, response)
    parts = URI.parse(url)
    if parts.host.match(/(www\.)?imgur.com/) then
      return Adapters::imgurdl(url, response)
    elsif parts.host.match(/^(www\.)?gfycat.com/) then
      return Adapters::gfycatdl(url, response)
    else
      raise NoAdapterError, "no adapter for #{parts.host.to_s.dump}"
    end
  end
end

class ReddPics
  def response_is_image(response)
    contenttype = response.mime_type
    if contenttype == nil then
      return false
    end
    # some video types are okay-ish for now
    return (contenttype.match("^image/") || contenttype.match("^video/webm"))
  end

  def contenttype_to_ext(response)
    contenttype = response.mime_type
    if contenttype then
      imgtype = contenttype.strip.split("/")[1]
      case imgtype
        when "bmp" then
          return "bmp"
        when "gif" then
          return "gif"
        when /jpe?g/ then
          return "jpg"
        when "png" then
          return "png"
        else
          if contenttype.match("^video/webm") then
            return "webm"
          else
            raise ArgumentError, "unknown image content type #{contenttype.dump} (imgtype = #{imgtype.inspect})!"
          end
      end
    end
  end

  def get_filename(url, response, index=nil)
    parts = URI.parse(url)
    # get rid of leading slash
    realpath = parts.path[1 .. -1]
    # just get the last part (the basename, duh)
    path = File.basename(realpath)
    # improvise if that didn't work for some reason
    path = if path.length == 0 then realpath.gsub("/", "-").gsub("\\", "-") else path end
    # get rid of the leading dot produced by File.extname
    ext = File.extname(path)[1 .. -1]
    # now get the, uh, *actual* file extension ...
    actual = contenttype_to_ext(response)
    realext = (((ext == nil) || (ext.size == 0)) ? actual : ext)
    # let's not fuck around, if the content-type isn't some type of image, it's b0rked
    if not actual then
      raise ArgumentError, "url #{url.dump} has a funky path, and did not set a 'Content-Type' header!!!"
    end
    # construct the new and improved filename
    basename = File.basename(path, realext).gsub(/\.$/, "")
    prefix = ((index != nil) ? "#{index}-" : "")
    return "#{prefix}#{basename}.#{realext}"
  end

  def get_listing(after)
    section = @opts[:section]
    listingopts = {t: @opts[:time], limit: @opts[:limit], after: after}
    case section
      when "new" then
        return @client.get_new(@subreddit, listingopts)
      when "hot" then
        return @client.get_hot(@subreddit, listingopts)
      when "top" then
        return @client.get_top(@subreddit, listingopts)
      when "controversial" then
        return @client.get_controversial(@subreddit, listingopts)
      else
        raise ArgumentError, "section #{section.dump} is unknown, or not yet handled"
    end
  end

  def handle_url(url, subfolder=nil, fileindex=nil)
    response = Util::download(url, headers: {referer: "https://www.reddit.com/r/#{@subreddit}"})
    if response then
      begin
        if response_is_image(response) then
          dlfolder = (subfolder ? File.join(@destfolder, subfolder) : @destfolder)
          filename = get_filename(url, response, fileindex)
          FileUtils.mkdir_p(dlfolder)
          # using chdir() to avoid a possible race condition (relatively unlikely, though)
          Dir.chdir(dlfolder) do
            if not File.file?(filename) then
              size = response.content_length
              sizestr = Filesize.new(size).to_f("MB")
              Logger.putline "writing image to file #{filename.dump}, size: #{sizestr} (#{size} bytes) ...".green
              File.open(filename, "w") do |fh|
                while true
                  data = response.readpartial
                  break if (data == nil)
                  fh << data
                end
              end
              @dlcount += 1
            else
              Logger.putline "already downloaded".yellow
            end
            Logger.putline
          end
        else
          begin
            links = Adapters::tryparse(url, response)
            name = links[:links]
            if links[:images].size == 0 then
              Logger.putline "didn't find any images!".yellow
            elsif links[:images].size == 1 then
              handle_url(links[:images].first[:url])
            else
              albumfolder = "album_#{links[:name]}"
              Logger.putline "downloading album to subdirectory #{albumfolder.dump} ...".green
              Logger.indent += 1
              links[:images].each_with_index do |img, idx|
                handle_url(img[:url], albumfolder, idx)
              end
              Logger.indent -= 1
            end
          rescue => err
            Logger.putline "couldn't process page: (#{err.class}) #{err.message}".red
          end
        end
      rescue => err
        Logger.putline "error: #{err.message}".red
      end
    else
      Logger.putline "skipping: downloading failed!".red
    end
    # end of handle_url
  end

  def walk_subreddit(after=nil)
    # todo: cache results? how? where?
    links = get_listing(after)
    $stderr.puts "++ received #{links.size} links ..."
    links.each do |chunk|
      url = Adapters::fixurl(chunk[:url])
      # neither title nor permalink are used (yet)
      # maybe create some kind of directory structure?
      title = chunk[:title]
      permalink = chunk[:permalink]
      isself = chunk[:is_self]
      if not isself then
        handle_url(url)
      end
    end
    if @pagecounter == 0 then
      $stderr.puts "=== done downloading images from /r/#{@subreddit}!"
    else
      $stderr.puts "** ############################# ..."
      $stderr.puts "** ##### opening next page ##### ..."
      $stderr.puts "** ############################# ..."
      $stderr.puts
      @pagecounter -= 1
      walk_subreddit(links.after)
    end
  end

  def initialize(client, subreddit, opts)
    @client = client
    @subreddit = subreddit
    @opts = opts
    @destfolder = @opts[:outputdir]
    @section = @opts[:section]
    @pagecounter = @opts[:maxpages] - 1
    @dlcount = 0
    begin
      walk_subreddit
    ensure
      $stderr.puts "=== statistics:"
      $stderr.puts "=== downloaded #{@dlcount} images"
    end
  end
end

opts = Trollop::options do
  banner (
    "Usage: #{File.basename $0} <subreddit ...> [<options>]\n" +
    "Valid options:"
  )
  opt(:outputdir,
      "Output directory to download images to. default is './r_<subredditname>'.\n" + 
      "You can use '%s' as template (for example, when downloading from several subreddits)",
    type: String)
  opt(:maxpages,  "Maximum pages to fetch (note: values over 10 may not work!)",
    type: Integer, default: 10)
  opt(:filesize,  "Maximum filesize for images",
    type: Integer, default: Filesize.from("5 MB").to_i)
  opt(:limit,     "How many links to fetch per page. Maximum value is 100",
    type: Integer, default: 100)
  opt(:section,   "What to download. options are 'new', 'hot', 'top', and 'controversial'.",
    type: String, default: "top")
  opt(:time,      "From which timespan to download. options are 'day', 'week', 'month', 'year', and 'all'.",
    type: String, default: "all")
  opt(:username,  "Your reddit username - overrides 'REDDPICS_USERNAME'",
    type: String)
  opt(:password,  "Your reddit password - overrides 'REDDPICS_PASSWORD'",
    type: String)
  opt(:apikey,    "Your API key - overrides 'REDDPICS_APIKEY'",
    type: String)
  opt(:appid,     "Your API appid - overrides 'REDDPICS_APPID'",
    type: String)
  opt(:apihelp,   "Prints a quick'n'dirty explanation how to get your API credentials", short: "-#")
end

if opts[:apihelp] then
  puts APIHELPSTRING
elsif ARGV.size > 0 then
  authinfo =
  {
    appid:    opts[:appid]    || ENV["REDDPICS_APPID"],
    apikey:   opts[:apikey]   || ENV["REDDPICS_APIKEY"],
    username: opts[:username] || ENV["REDDPICS_USERNAME"],
    password: opts[:password] || ENV["REDDPICS_PASSWORD"],
  }
  Trollop::die(:limit,    "must be less than 100") if opts[:limit] > 100
  Trollop::die(:maxpages, "value must be larger than zero") if opts[:maxpages] == 0
  Trollop::die(:apikey,   "must be set (try '--apihelp')") if not authinfo[:apikey]
  Trollop::die(:time,     "uses an invalid timespan") if not opts[:time].match(/^(day|week|month|year|all)$/)
  client = Redd.it(:script, authinfo[:appid], authinfo[:apikey], authinfo[:username], authinfo[:password],
    user_agent: "ImageDownloader (ver1.0)"
  )
  client.authorize!
  ARGV.each do |subreddit|
    instanceopts = opts.dup
    if opts[:outputdir] then
      if opts[:outputdir].match(/%s/) then
        # instead of using sprintf, use String#% and %{whatever} notion?
        instanceopts[:outputdir] = sprintf(opts[:outputdir], subreddit)
      end
    else
      instanceopts[:outputdir] = "./r_#{subreddit}"
    end
    ReddPics.new(client, subreddit, instanceopts)
  end
else
  puts "usage: #{File.basename $0} <subreddit> [ -o <destination-folder> [... <other options>]]"
  puts "try #{File.basename $0} --help for other options"
end


