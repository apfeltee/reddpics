#!/usr/bin/ruby

require "fileutils"
require "uri"
require "http"
require "redd"
require "trollop"

module Util
  def self.download(url, headers: {}, maxredirs: 5)
    $stderr << "-- wget #{url.dump} ... "
    begin
      response = HTTP.headers(headers).get(url)
      location = response["Location"]
      if response.code >= 400 then
        $stderr << "failed: HTTP status #{response.code} #{response.reason}\n"
        return nil
      elsif location then
        if location.match(/^https?:/) then
          if not location.match(/imgur.com\/removed/) then
            if maxredirs == 0 then
              $stderr << "failed: too many redirects\n"
              return nil
            end
            $stderr << "redirects to #{location.dump}\n"
            return download(location, headers: headers, maxredirs: maxredirs - 1)
          else
            $stderr << "image has been removed (imgur hackery)\n"
            return nil
          end
        else
          $stderr << "failed: redirects to a bad url (location: #{location.dump})\n"
          return nil
        end
      end
      $stderr << "done!\n"
      return response
    rescue => err
      $stderr << "failed: (#{err.class}) #{err.message}\n"
      return nil
    end
  end
end

class ReddPics
  def fix_url(url)
    parts = URI.parse(url)
    # don't modify imgur.com/a/<id> urls
    if (parts.host == "imgur.com") && (not parts.path.match(/\/(a)\//)) then
      parts.host = "i.imgur.com"
      parts.path += ".jpg"
      return parts.to_s
    elsif parts.path.match(/\.gifv$/) then
      parts.path = parts.path.gsub(/\.gifv$/, ".gif")
      return parts.to_s
    end
    return url
  end

  def guess_is_image(url)
    parts = URI.parse(url)
    if parts.host.match(/^(i.imgur.com|imgur.com|i.reddituploads.com)$/) then
      return true
    elsif parts.path.match(/\.(jpe?g|gif|png)$/i) then
      return true
    end
    return false
  end

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
      when "top" then
        return @client.get_top(@subreddit, listingopts)
      else
        raise ArgumentError, "section #{section.dump} is unknown, or not yet handled"
    end
  end

  def handle_url(url, origurl)
    $stderr.puts "++ checking #{url.dump} ..."
    response = Util::download(url, headers: {referer: "https://www.reddit.com/r/#{@subreddit}"})
    if response then
      begin
        filename = get_filename(origurl, response)
        if response_is_image(response) then
          FileUtils.mkdir_p(@destfolder)
          Dir.chdir(@destfolder) do
            if not File.file?(filename) then
              $stderr.puts "-- writing image to file #{filename.dump} ..."
              File.open(filename, "w") do |fh|
                while true
                  data = response.readpartial
                  break if (data == nil)
                  fh << data
                end
              end
            else
              $stderr.puts "-- already downloaded"
            end
          end
        else
          $stderr.puts "-- skipping: 'Content-Type' does not report as an image!"
        end
      rescue => err
        $stderr.puts "-- error: #{err.message}"
      end
    else
      $stderr.puts "-- skipping: downloading failed!"
    end
    $stderr.puts
  end

  def walk_subreddit(after=nil)
    links = get_listing(after)
    $stderr.puts "++ received #{links.size} links ..."
    links.each do |chunk|
      origurl = chunk[:url]
      url = fix_url(origurl)
      title = chunk[:title]
      permalink = chunk[:permalink]
      isself = chunk[:is_self]
      if not isself then
        handle_url(url, origurl)
      end
    end
    if @pagecounter == 0 then
      $stderr.puts "=== done! ==="
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
    walk_subreddit
  end
end

opts = Trollop::options do
  banner (
    "Usage: #$0 <subreddit> [<options>]\n" +
    "Valid options:"
  )
  opt(:outputdir, "Output directory to download images to. default is './r_<subredditname>'",
    type: String)
  opt(:maxpages,  "Maximum pages to fetch (note: values over 10 may not work!)",
    type: Integer, default: 10)
  opt(:limit,     "How many links to fetch per page. Maximum value is 100 (default is 100)",
    type: Integer, default: 100)
  opt(:section,   "What to download. options are 'hot', 'top', and 'controversial'. default is 'top'",
    type: String, default: "top")
  opt(:time,      "From which timespan to download. options are day, week, month, year, and all. default is all",
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
  subreddit = ARGV.first
  opts[:outputdir] = if opts[:outputdir] then opts[:outputdir] else "./r_#{subreddit}" end
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
  ReddPics.new(client, subreddit, opts)
else
  puts "usage: #$0 <subreddit> [ -o <destination-folder> [... <other options>]]"
  puts "try #$0 --help for other options"
end


