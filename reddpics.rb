#!/usr/bin/ruby

require "fileutils"
require "uri"
require "http"
require "redd"
require "nokogiri"
require "trollop"

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

  def self.putline(str)
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
        Logger.write "failed: HTTP status #{response.code} #{response.reason}\n"
        return nil
      elsif location then
        if location.match(/^https?:/) then
          if not location.match(/imgur.com\/removed/) then
            if maxredirs == 0 then
              Logger.write "failed: too many redirects\n"
              return nil
            end
            $stderr << "ok: redirects to #{location.dump}\n"
            return download(location, headers: headers, maxredirs: maxredirs - 1)
          else
            Logger.write "failed: image has been removed (imgur hackery)\n"
            return nil
          end
        else
          Logger.write "failed: redirects to a bad url (location: #{location.dump})\n"
          return nil
        end
      end
      Logger.write "ok\n"
      return response
    rescue => err
      Logger.write "failed: (#{err.class}) #{err.message}\n"
      return nil
    end
  end

  # disgusting hack incoming
  def self.imgurdl(url)
    parts = URI.parse(url)
    result = {id: nil, title: "", images: []}
    title = nil
    if not parts.host.match(/^((i|m)\.imgur|imgur|www\.imgur)\.com$/) then
      raise ArgumentError, "url #{url.dump} does not look like an imgur url"
    elsif (not parts.path) || (parts.path == "/") then
      raise ArgumentError, "can't download the entire frontpage. sorry :<"
    end
    # user favorites are almost guaranteed to fail.
    # don't be mad at me, be mad at imgur for their shitty API
    if parts.path.match("^/a/") then
      result[:id] = parts.path.split("/")[-1]
      source = "http://imgur.com/ajaxalbums/getimages/#{result[:id]}/hit.json"
      response = Util::download(source)
      if not response then
        raise ArgumentError, "could not download json information (#{source.dump})"
      end
      json = JSON.load(response.to_s)
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
      result[:id] = parts.path.split("/").first
      response = Util::download(url)
      if response then
        document = Nokogiri::HTML(response.to_s)
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
      else
        raise ArgumentError, "could not download page"
      end
    end
    return result
  end
end

class ReddPics
  def response_is_image(response)
    contenttype = response.mime_type
    if contenttype == nil then
      return false
    end
    return (contenttype.match(/^image\//))
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
          raise ArgumentError, "unknown image content type #{contenttype.dump} (imgtype = #{imgtype.inspect})!"
      end
    end
  end

  def get_filename(url, response)
    parts = URI.parse(url)
    path = parts.path[1 .. -1].gsub("/", "-").gsub("\\", "-")
    ext = File.extname(path)[1 .. -1]
    actual = contenttype_to_ext(response)
    if ext && ext.match(/(jpe?g|gif|png)$/i) then
      if actual && (actual != ext) then
        return File.basename(path, ext) + actual
      end
      return path
    end
    if not actual then
      raise ArgumentError, "url #{url.dump} has a funky path, and did not set a 'Content-Type' header!!!"
    end
    return path + "." + actual
  end

  def get_listing(after)
    section = @opts[:section]
    listingopts = {t: @opts[:time], limit: @opts[:limit], after: after}
    case section
      when "hot" then
        return @client.get_hot(@subreddit, listingopts)
      when "top" then
        return @client.get_top(@subreddit, listingopts)
      else
        raise ArgumentError, "section #{section.dump} is unknown, or not yet handled"
    end
  end

  def handle_url(url, subfolder=nil)
    Logger.putline "checking #{url.dump} ..."
    response = Util::download(url, headers: {referer: "https://www.reddit.com/r/#{@subreddit}"})
    if response then
      begin
        if response_is_image(response) then
          dlfolder = (subfolder ? File.join(@destfolder, subfolder) : @destfolder)
          filename = get_filename(url, response)
          FileUtils.mkdir_p(dlfolder)
          Dir.chdir(dlfolder) do
            if not File.file?(filename) then
              Logger.putline "writing image to file #{filename.dump} ..."
              File.open(filename, "w") do |fh|
                while true
                  data = response.readpartial
                  break if (data == nil)
                  fh << data
                end
              end
              @dlcount += 1
            else
              Logger.putline "already downloaded"
            end
          end
        else
          # this part is shit, because we repeating logic here. bad, awful, rewrite, etc.
          parts = URI.parse(url)
          if parts.host.match(/(www\.)?imgur.com/) then
            Logger.putline "looks like an imgur page; will try to parse it"
            Logger.indent += 1
            begin
              links = Util::imgurdl(url)
              size = links[:images].size
              if size > 0 then
                if size == 1 then
                  Logger.putline "downloading from single-image page ..."
                  handle_url(links[:images].first[:url])
                  Logger.indent -= 1
                else # album or somesuch
                  albumfolder = "album_#{links[:id]}"
                  Logger.putline "downloading album to subdirectory #{albumfolder.dump} ..."
                  Logger.indent += 1
                  links[:images].each do |img|
                    handle_url(img[:url], albumfolder)
                  end
                  Logger.putline "*** album download done ***"
                  Logger.indent -= 1
                end
              else
                Logger.putline "page does not contain any images :("
              end
            rescue => err
              Logger.putline "couldn't parse imgur url: (#{err.class}) #{err.message}"
              if err.is_a?(TypeError) then
                err.backtrace.each do |line|
                  Logger.putline line
                end
              end
            end
            Logger.indent -= 1
          else
            Logger.putline "skipping: 'Content-Type' does not report as an image!"
          end
        end
      rescue => err
        Logger.putline "error: #{err.message}"
      end
    else
      Logger.putline "skipping: downloading failed!"
    end
    # end of handle_url
  end

  def walk_subreddit(after=nil)
    links = get_listing(after)
    $stderr.puts "++ received #{links.size} links ..."
    links.each do |chunk|
      url = chunk[:url]
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
    @pagecounter = @opts[:maxpages]
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
  opt(:limit,     "How many links to fetch per page. Maximum value is 100",
    type: Integer, default: 100)
  opt(:section,   "What to download. options are 'hot', 'top', and 'controversial'.",
    type: String, default: "top")
  opt(:time,      "From which timespan to download. options are day, week, month, year, and all.",
    type: String, default: "all")
  opt(:username,  "Your reddit username - overrides 'REDDPICS_USERNAME'",
    type: String)
  opt(:password,  "Your reddit password - overrides 'REDDPICS_PASSWORD'",
    type: String)
  opt(:apikey,    "Your API key - overrides 'REDDPICS_APIKEY'",
    type: String)
  opt(:appid,     "Your API appid - overrides 'REDDPICS_APPID'",
    type: String)
end

if ARGV.size > 0 then
  authinfo =
  {
    appid:    opts[:appid]    || ENV["REDDPICS_APPID"],
    apikey:   opts[:apikey]   || ENV["REDDPICS_APIKEY"],
    username: opts[:username] || ENV["REDDPICS_USERNAME"],
    password: opts[:password] || ENV["REDDPICS_PASSWORD"],
  }
  Trollop::die(:limit,  "must be less than 100") if opts[:limit] > 100
  Trollop::die(:apikey, "must be set (visit https://www.reddit.com/wiki/api)") if not authinfo[:apikey]
  Trollop::die(:time,   "uses an invalid timespan") if not opts[:time].match(/^(day|week|month|year|all)$/)
  client = Redd.it(:script, authinfo[:appid], authinfo[:apikey], authinfo[:username], authinfo[:password],
    user_agent: "ImageDownloader (ver1.0)"
  )
  client.authorize!
  ARGV.each do |subreddit|
    instanceopts = opts.dup
    if opts[:outputdir] then
      if opts[:outputdir].match(/%s/) then
        instanceopts[:outputdir] = sprintf(opts[:outputdir], subreddit)
      end
    else
      instanceopts[:outputdir] = "./r_#{subreddit}"
    end
    #require "pp"; pp [subreddit, instanceopts]
    ReddPics.new(client, subreddit, instanceopts)
  end
else
  puts "usage: #{File.basename $0} <subreddit> [ -o <destination-folder> [... <other options>]]"
  puts "try #{File.basename $0} --help for other options"
end


