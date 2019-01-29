#!/usr/bin/ruby

require "fileutils"
require "uri"
require "uri/http"
require "cgi"
require "pp"
require "optparse"
require "yaml"
require "redd"
require "http"
require "nokogiri"
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

DEFAULT_CONFIG_VALUES = {
  logfile: "log_%s.txt",
  maxpages: 20,
  filesize: "10MB",
  limit: 100,
  section: "top",
  time: "all",
  template: "%{title}-%{id}",
  converttowebp: false,
  tm_connect: 5,
  tm_read: 5,
  tm_write: 5,
}

# exceptions
class NoAdapterError < StandardError
end

# shitty logger
class Logger
  @indent = 0
  @otherfile = nil

  def self.putindent
    if @indent < 0 then
      @indent = 0
    end
    write("  " * @indent)
  end

  def self.putprefix
    write("-- ")
  end

  def self.putline(str=nil, color: nil)
    putindent
    putprefix
    if not str.nil? then
      write(str, color: color)
    end
    write("\n")
  end

  def self.put(str)
    putindent
    putprefix
    write(str)
  end

  def self.write(str, color: nil)
    if color then
      $stderr << str.colorize(color)
    else
      $stderr << str
    end
    if (not @otherfile.nil?) && (not @otherfile.closed?) then
      @otherfile << str
    end
  end

  class << self
    attr_accessor :indent, :otherfile
  end
end

module Util
  def self.download(url, headers: {}, maxredirs: 5, tm_connect: 5, tm_read: 5, tm_write: 5)
    now = Time.now
    tstamp =  sprintf("%02d:%02d:%02d", now.hour, now.min, now.sec)
    # maybe add {"accept-encoding" => "identity"}?
    Logger.put("[#{tstamp}] wget(#{url.dump}) ... ")
    begin
      #headers["accept-encoding"] = "identity"
      response = HTTP.timeout(:global, connect: tm_connect, read: tm_read, write: tm_write).headers(headers).follow(true).get(url)
      if response.code >= 400 then
        Logger.write("failed: HTTP status #{response.code} #{response.reason}\n", color: :red)
        return nil
      else
        # when an image had been removed from imgur, the image
        # url (i.e., http://i.imgur.com/whatever.jpg) does a 302 to
        # /removed.png, which, itself, is served as 200 OK.
        # hence this hack.
        # todo: this really shouldn't need to be necessary, but imgur is run by retards, so...
        if response.uri.host.match(/imgur\.com$/) && response.uri.path.match("/removed.png") then
          Logger.write("failed: image has been removed (imgur hackery)\n", color: :red)
          return nil
        end
      end
      Logger.write("ok\n", color: :green)
      return response
    rescue => err
      Logger.write("failed: (#{err.class}) #{err.message}\n", color: :red)
      $stderr.puts(err.backtrace)
      return nil
    end
  end

  def self.file_exists?(path, altexts=[".webp"])
    if not File.file?(path) then
      bname = File.basename(path)
      dirn = File.dirname(path)
      extn = File.extname(bname)
      blank = File.basename(bname, extn)
      altexts.each do |ext|
        fname = sprintf("%s%s", blank, ext)
        fpath = File.join(dirn, fname)
        if File.file?(fpath) then
          return true
        end
      end
      return false
    end
    return true
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

  def self.sanitize_filename(filename, max_length: 128)
    # get rid of any junk space
    filename.strip!
    # get rid of dots
    filename.gsub!(/\./, '') while filename.match(/\./)
    # get only the filename, not the whole path
    filename.gsub!(/^.*(\\|\/)/, '')
    # replace non-ascii characters
    filename.gsub!(/[^0-9A-Za-z.\-]/, '_')
    # get rid of double underscores
    filename.gsub!(/__/, '_') while filename.match(/__/)
    # get rid of underscore at beginning of string
    filename.gsub!(/^_/, '') while filename.match(/^_/)
    # get rid of underscore at end of string
    filename.gsub!(/_$/, '') while filename.match(/_$/)
    # finally, strip down to $max_length
    return filename[0 .. max_length]
  end

  def self.read_local_configfile(name: "reddpics")
    cfgpath = File.expand_path("~/.#{name}.cfg")
    if File.file?(cfgpath) then
      begin
        rt = YAML.load_file(cfgpath).map{|k, v| [k.to_sym, v]}.to_h
        Logger.putline("configfile: loaded configuration file #{cfgpath.dump}")
        failed = false
        %i(redditusername redditpassword redditapikey redditappid).each do |k|
          if not rt.include?(k) then
            Logger.putline("configfile: missing key #{k.to_s.dump}!")
            failed = true
          end
        end
        return rt
      rescue => ex
        Logger.putline("configfile: YAML.load_file failed: (#{ex.class}) #{ex.message}")
      end
    else
      Logger.putline("configfile: file #{cfgpath.dump} does not exist")
    end
    return {}
  end

  def self.get_local_config(defaults)
    newopts = defaults.dup
    rt = read_local_configfile
    rt.each do |k, v|
      if defaults.include?(k) then
        v = case defaults[k].class
          when String then
            v.to_s
          when Numeric then
            v.to_i
          else
            v
        end
      end
      newopts[k] = v
    end
    return newopts
  end

  # attempt to avoid redirects (in an extremely primitive way)
  def self.fixurl(url)
    parts = URI.parse(url.scrub)
    if parts.host.match(/^(www\.)?gfycat.com/) then
      # http:// will always redirect to https://, and www.gfycat.com
      # seems to always redirect to gfycat.com ...
      # hence this correction here.
      parts.scheme = "https"
      if parts.host == "www.gfycat.com" then
        parts.host = "gfycat.com"
      end
      return parts.to_s
    elsif parts.host == "i.reddituploads.com" then
      # reddit stores their urls for reddituploads.com
      # with escaped elements - which garbles the access code, thus
      # making the actual url inaccessible. this'll (usually) fix it.
      return CGI.unescapeHTML(url)
    elsif (parts.host == "i.imgur.com") && parts.path.end_with?(".gifv") then
      # imgur has an admittedly neat feature, in which gifs are automatically
      # converted to webm or mp4, BUT .gifv is obviously not a real thing;
      # instead it is a placeholder document page that embeds the new
      # converted video. extracting that video is possible per-se, but
      # imgur seems to rather aggressively redirect from the .gifv page to
      # the gallery page! so just use the old .gif, even if it's a few dozen
      # times larger.
      parts.path.gsub!(/\.gifv/, ".gif")
      return parts.to_s
    end
    return url
  end

  def self.replace_extension(filename, newext, icase=true)
    fext = File.extname(filename)
    rx = Regexp.new(Regexp.quote(fext) + "$", icase ? Regexp::IGNORECASE : 0)
    return filename.gsub(rx, newext)
  end
end

class Adapters
  def initialize(opts, dlopts)
    @opts = opts
    @dloptions = dlopts
    @haveimgurapi = false
    if @opts[:imgurappid] then
      @haveimgurapi = true
    else
      Logger.putline("no app-id registered for imgur! scraping will not be available.")
    end
  end

  # disgusting hack incoming:
  # all of this is completely stupid.
  # imgur changed their pages, so as to make it impossible
  # to scrape albums etc. without an api key.

  def imgurmakeuri(typ, id)
    # these are the most common types. there are many others, but idgaf atm
    mapping = {
      :album => "https://api.imgur.com/3/album/%s/images",
      :gallery => "https://api.imgur.com/3/gallery/%s/images",
      :image => "https://api.imgur.com/3/image/%s",
    }
    if mapping.key?(typ) then
      return sprintf(mapping[typ], id)
    end
    raise NoAdapterError, "imgur-api: unknown/unimplemented type #{typ}"
  end

  def imgurapi(typ, id)
    appid = @opts[:imgurappid]
    uri = imgurmakeuri(typ, id)
    clheader = sprintf("Client-ID %s", appid)
    res = Util.download(uri, headers: {"Authorization" => clheader}, **@dloptions)
    rawjson = res.body.to_s
    parsedjson = JSON.parse(rawjson)
    if parsedjson["success"] == true then
      # the json view might just be a map. if so, return it as an array
      data = parsedjson["data"]
      if data.is_a?(Array) then
        return data
      end
      return [data]
    end
    return []
  end

  def imgurdl(typ, id)
    result = {name: nil, title: "", images: []}
    data = imgurapi(typ, id)
    data.each do |chunk|
      result[:images].push({url: chunk["link"], title: chunk["title"], description: chunk["description"]})
    end
    return result
  end

  # noembed.com is for sites that technically have an api,
  # but are run by anal-retentive cunts who'd make you
  # pay $5000 just to retrieve a file.
  # fuck you flickr
  def noembed(url, response)
    jsonurl = Util.build_uri({
      scheme: "https",
      host: "noembed.com",
      path: "/embed",
      query: "url=#{url}"
    })
    jsonresponse = Util.download(jsonurl.to_s, **@dloptions)
    if jsonresponse then
      jsondata = JSON.parse(jsonresponse.to_s)
      if (mediaurl = jsondata["media_url"]) != nil then
        return {name: nil, images: [{url: mediaurl, title: jsondata["title"], description: nil}]}
      else
        raise ArgumentError, "noembed json response didn't contain 'media_url'"
      end
    else
      raise ArgumentError, "noembed.com call failed"
    end
  end

  def handle_imgur(uri, *rest)
    if @haveimgurapi then
      pathparts = uri.path.split("/").reject(&:empty?)
      if uri.path.start_with?("/a/") then
        id = pathparts[1]
        return imgurdl(:album, id)
      elsif uri.path.start_with?("/gallery/") then
        id = pathparts[1]
        return imgurdl(:gallery, id)
      else
        id = pathparts[0]
        if (pathparts.length == 1) then
          return imgurdl(:image, id)
        else
          raise NoAdapterError, "failed to figure out type of imgur page for #{uri.to_s.inspect}"
        end
      end
    end
    raise NoAdapterError, "cannot use imgur api without api key"
  end

  # can't just do https://zippy.gfycat.com/... because gfycat may host webms on different hosts
  def handle_gfycat(uri, response)
    #### unused code ####
    info = {name: nil, images: []}
    upath = uri.path.split("/").map(&:strip).reject(&:empty?)
    if (upath[0] =~ /^gifs?$/) && (upath[1] =~ /^details?$/) then
      # uri is something like 'https://gfycat.com/gifs/detail/<id>'
      # so get last item
      info[:name] = upath[-1]
    else
      info[:name] = upath[0]
    end
    # https://api.gfycat.com/v1/gfycats/<id>
    apiurl = Util.build_uri({scheme: "https", host: "api.gfycat.com", path: File.join("/v1/gfycats", info[:name])})
    apiresponse = Util.download(apiurl.to_s, **@dloptions)
    if apiresponse then
      json = JSON.parse(apiresponse.to_s)
      gfyitem = json["gfyItem"]
      info[:images].push({url: gfyitem["webmUrl"], title: gfyitem["redditIdText"], description: ""})
      return info
    else
      raise ArgumentError, "gfycat api call failed!"
      #return noembed(uri, nil)
    end
  end


  def handle_flickr(url, response)
    return noembed(url, response)
  end

  def handle_deviantart(url, response)
    return noembed(url, response)
  end

  # attempt to extract a known adapter.
  # basically, if the http response responds with a mimetype that
  # is something other than "image/*", the most likely reason is that
  # it is hosted on a page that is also responding (duh).
  # (in other words, if the response code is something other than 200, this will fail)
  # in those cases, this function resumes download via an adapter, that
  # parses/extracts the final file(s).
  def tryparse(url, response)
    parts = URI.parse(url)
    if parts.host.match(/(www\.)?imgur.com/) then
      return handle_imgur(parts, response)
    elsif parts.host.match(/^(www\.)?gfycat.com/) then
      return handle_gfycat(parts, response)
    elsif (parts.host == "flickr.com") || (parts.host == "www.flickr.com") || (parts.host == "flic.kr") then
      return handle_flickr(parts, response)
    elsif (parts.host.match(/.*\.deviantart.com$/)) then
      return handle_deviantart(parts, response)
    else
      # todo: do username subdomain check for deviantart
      raise NoAdapterError, "no adapter for #{parts.host.to_s.dump}"
    end
  end
end

class ReddPics
  # this variable is modified with each call of ReddPics
  # to keep track of total downloaded files
  @@total_downloaded_filecount = 0
  @@total_downloaded_filebytes = 0

  # primitive content_type check for mime types we can actually
  # use
  def response_is_image(response)
    contenttype = response.mime_type
    if contenttype == nil then
      return false
    end
    # some video types are okay-ish for now
    return (contenttype.match("^image/") || contenttype.match("^video/webm"))
  end

  # turn a mime type into an extension we can use
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

  # extract a safe-ish, reusable filename
  def get_filename(url, response: nil, info: nil, fileindex: nil, is_album: false)
    basename = nil
    # this chunk of awful does not apply to albums
    if not is_album then
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
      # let's not mess around, if the content-type isn't some type of image, it's b0rked
      # and also if the webmaster does some pants-on-head retarded bullshit
      # like using backward slashes, just disregard the thing
      if (not actual) && (not is_album) then
        raise ArgumentError, "url #{url.dump} has a funky path, and did not set a 'Content-Type' header!!!"
      end
      # construct the new and improved filename
      # get rid of dot (realext is without leading dot)
      basename = File.basename(path, realext)[0 .. -2]
    end
    # make prefix if not nil
    prefix = (((fileindex != nil) && (not is_album)) ? "#{fileindex}-" : "")
    # lump it all together
    threadid = info.id
    # if the user deleted their account, it'd become "[deleted]",
    # so get rid of the brackets
    username = info.author.name.gsub(/[\[\]]/, "")
    score = info.score
    title = Util.sanitize_filename(info.title)
    #if the title is empty, substitute with basename
    if title.empty? then
      title = basename
    end
    vars =
    {
      name:     basename,
      filename: basename,
      id:       threadid,
      thread:   threadid,
      username: username,
      author:   username,
      score:    score,
      points:   score,
      created:  info.created.to_i,
      title:    title    
    }
    tplvars = @opts[:template].dup
    # warning: hack follows
    if not fileindex.nil? then
      # to reduce length of filenames, strip the %{title} tag
      # if we're downloading images for an album.
      # technically, we could just erase :title from $vars, but
      # then there still could be a leading underscore/dash, which would be bad, obviously
      tplvars.gsub!(/%{title}/, '')
      # just in case the filename starts with a dash or underscore, or somesuch
      tplvars.gsub!(/^[\-_]/, '')
    end
    formatted = (tplvars % vars)
    tmp = prefix + formatted
    if not is_album then
      tmp << "." << realext
    end
    return tmp
  end

  def handle_url(url, subfolder: nil, fileindex: nil, info: {})
    if not fileindex then
      Logger.putline("thread: #{info.title.dump} (https://redd.it/#{info.id})", color: :blue)
    end
    response = Util.download(url, headers: {referer: "https://www.reddit.com/r/#{@subreddit}"}, **@dloptions)
    if response then
      begin
        if response_is_image(response) then
          dlfolder = (subfolder ? File.join(@destfolder, subfolder) : @destfolder)
          filename = get_filename(url, response: response, fileindex: fileindex, info: info)
          FileUtils.mkdir_p(dlfolder) unless File.directory?(dlfolder)
          # using chdir() to avoid a possible race condition (relatively unlikely, though)
          Dir.chdir(dlfolder) do
            if not Util.file_exists?(filename) then
              size = response.content_length || 0
              sizestr = Filesize.new(size).to_f("MB")
              if size >= @maxfilesize then
                Logger.putline("file is too large (#{sizestr} MB, #{size} bytes)", color: :red)
              else
                Logger.putline("writing image to file #{filename.dump} (#{sizestr} MB, #{size} bytes) ...", color: :green)
                File.open(filename, "w") do |fh|
                  # a neat feature of http.rb is that it only retrieves
                  # the header at first -- which makes HTTP queries very lightweight.
                  # the actual body is downloaded later (http.rb calls it streaming),
                  # and here's a prime example of how useful this actually is!
                  while true do
                    data = response.readpartial
                    if (data == nil) then
                      break
                    end
                    @@total_downloaded_filebytes += data.bytesize
                    fh.write(data)
                  end
                end
                @dlcount += 1
                @cachedlinks[info.id] = info
                post_download(filename)
              end
            else
              Logger.putline("already downloaded", color: :yellow)
            end
          end
        else
          begin
            links = @adapters.tryparse(url, response)
            if links[:images].size == 0 then
              Logger.putline("didn't find any images!", color: :yellow)
            elsif links[:images].size == 1 then
              handle_url(links[:images].first[:url], info: info)
            else
              #albumfolder = "album_#{links[:name]}_#{info[:id]}"
              albumfolder = "album_#{get_filename(nil, info: info, is_album: true)}"
              Logger.putline("downloading album to subdirectory #{albumfolder.dump} ...", color: :green)
              Logger.indent += 1
              links[:images].each_with_index do |img, idx|
                handle_url(img[:url], subfolder: albumfolder, fileindex: idx, info: info)
              end
              Logger.indent -= 1
            end
          rescue => err
            Logger.putline("couldn't process page: (#{err.class}) #{err.message}", color: :red)
            pp err.backtrace
          end
        end
      rescue => err
        Logger.putline("error: #{err.message}", color: :red)
        pp err.backtrace
      end
    else
      Logger.putline("skipping: downloading failed!", color: :red)
    end
    # end of handle_url
  end

  def get_listing(after)
    section = @opts[:section]
    listingopts = {t: @opts[:time], limit: @opts[:limit], after: after}
    begin
      case section
        when "new" then
          return @client.subreddit(@subreddit, listingopts).new(listingopts)
        when "hot" then
          return @client.subreddit(@subreddit, listingopts).hot(listingopts)
        when "top" then
          return @client.subreddit(@subreddit).top(listingopts)
        when "controversial" then
          return @client.subreddit(@subreddit).controversial(listingopts)
        else
          raise ArgumentError, "section #{section.dump} is unknown, or not yet handled"
      end
    rescue Redd::Forbidden, Redd::NotFound => err
      Logger.putline("cannot access /r/#{@subreddit}: #{err}", color: :red)
      return nil
    rescue Redd::ServerError, HTTP::ConnectionError, HTTP::TimeoutError => err
      Logger.putline("#{err.class}: something went really wrong", color: :red)
      return nil
    rescue Redd::TokenRetrievalError => err
      # most likely reason is that session has timed out
      # if login fails, let error propagate
      Logger.putline("received client error #{err.class}: #{err.message}", color: :red)
      if @loginattempts != 5 then
        Logger.putline("trying to login again", color: :red)
        login
        return get_listing(after)
      else
        Logger.putline("Tried to login 5 times", color: :red)
        Logger.putline("Either your credentials are wrong, or something else is failing")
        Logger.putline("Aborting")
        return nil
      end
    rescue Redd::APIError => err
      Logger.putline("Unhandled #{err.class}: #{err}")
      return nil
    end
  end

  def walk_subreddit(after=nil)
    links = get_listing(after)
    if (links.nil?) || (links.empty?) then
      Logger.putline("get_listing didn't return anything", color: :red)
    else
      begin
        $stderr.puts "++ received #{links.to_a.size} links ..."
        links.each do |chunk|
          begin
            id = chunk.id
            url = Util.fixurl(chunk.url.scrub.force_encoding("ascii"))
            title = chunk.title
            permalink = chunk.permalink
            isself = chunk.is_self
            if not isself then
              if @cachedlinks.has_key?(id) then
                Logger.putline("/r/#{@subreddit}: already seen thread #{id} (title: #{title.dump}, url: #{url.dump})", color: :green)
              else
                handle_url(url, info: chunk)
                Logger.putline
              end
            end
          rescue URI::InvalidURIError => err
            Logger.putline("URI::InvalidURIError: #{err.message}", color: :red)
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
    end
  end

  def writecache
    cacheme = {}
    @cachedlinks.each do |id, info|
      if info.is_a?(String) then
        #cacheme[id] = info
      else
        title = (info.is_a?(Hash) ? info["title"] : info.title)
        url   = (info.is_a?(Hash) ? info["url"] : info.url)
        thrurl = sprintf("https://reddit.com/r/%s/comments/%s/", @subreddit, id)
        cacheme[id] = {title: title, url: url, thread: thrurl}
      end
    end
    begin
      $stderr.puts("writing cache (please be patient!) ...")
      File.open(@cachefile, @cachemode) do |fh|
        #fh << JSON.pretty_generate(@cachedlinks)
        #fh << JSON.dump(@cachedlinks)
        #JSON.dump(@cachedlinks, fh)
        fh.puts(JSON.pretty_generate(cacheme))
      end
    rescue Interrupt => err
      Logger.putline("caching was interrupted! trying again ...")
      writecache
    rescue => err
      Logger.putline("failed to write cache to #{@cachefile}: (#{err.class}) #{err}")
    else
      $stderr.puts("=== wrote cache to #{@cachefile}")
    end
  end

  def login
    @client = Redd.it(
      client_id: @opts[:redditappid],
      secret: @opts[:redditapikey],
      username: @opts[:redditusername],
      password: @opts[:redditpassword],
      user_agent: "ImageDownloader (ver1.0)"
    )
    @loginattempts += 1
  end

  def post_download(filename)
    begin
      if @wantwebp then
        postdl_convert_webp(filename)
      end
    rescue => ex
      Logger.putline(sprintf("post_download: error: (%s) %s", ex.class.name, ex.message), color: :red)
    end
  end

  def postdl_convert_webp(infile)
    fext = File.extname(infile)
    if fext.match(/\.(jpe?g|png)$/i) then
      fdest = Util.replace_extension(infile, ".webp")
      Logger.putline("webp: converting to #{fdest.dump} ...")
      Thread.new{
        if system("gm", "convert", infile, fdest) then
          Logger.putline("webp: deleting original #{infile.dump} ...")
          FileUtils.rm_f(infile)
        else
          Logger.putline("webp: command 'gm convert' failed (maybe you need to install graphicsmagick first?)")
          FileUtils.rm_f(fdest) if File.file?(fdest)
        end
      }.join
    else
      Logger.putline("webp: #{infile.dump} cannot be converted: only JPEG and PNG supported")
    end
  end

  def initialize(subreddit, opts)
    @subreddit = subreddit
    @opts = opts
    @wantwebp = @opts[:converttowebp]
    @destfolder = @opts[:outputdir]
    @section = @opts[:section]
    @pagecounter = @opts[:maxpages] - 1
    @maxfilesize = Filesize.from(@opts[:filesize]).to_i
    @dlcount = 0
    @loghandle = nil
    @loginattempts = 0
    # todo: improve caching methods
    @cachefile = File.join(@destfolder, ".cache_#{@subreddit}.json")
    @cachedlinks = {}
    @cachemode = "w"
    @dloptions = {
      tm_connect: @opts[:tm_connect],
      tm_read: @opts[:tm_read],
      tm_write: @opts[:tm_write],
    }
    $stderr.printf("dloptions=%p\n", @dloptions)
    @adapters = Adapters.new(@opts, @dloptions)
    FileUtils.mkdir_p(@destfolder) unless File.directory?(@destfolder)
    if @opts[:logfile] then
      @logfile = sprintf(@opts[:logfile], @subreddit)
      @loghandle = File.open(@logfile, "wb")
      @loghandle.puts("### file generated by reddpics for /r/#{@subreddit}")
      @loghandle.puts("### logging started: #{Time.now}")
      @loghandle.puts
      Logger.putline("logfile will be written to #{@logfile.dump}")
      Logger.otherfile = @loghandle
    end
    login
    begin
      if File.exist?(@cachefile) then
        @cachemode = "w"
        if not File.file?(@cachefile) then
          raise IOError, "cache file #{@cachefile} is not a regular file!"
        end
        # now load the file
        begin
          @cachedlinks = JSON.load(File.read(@cachefile))
        rescue JSON::JSONError => err
          Logger.putline("could not load cache from #{@cachefile}: (#{err.class}) #{err.message}", color: :red)
        end
      end
      walk_subreddit
    ensure
      if @loghandle then
        $stderr.puts("=== closing log #{@logfile}")
        @loghandle.puts
        @loghandle.puts("### logging finished: #{Time.now}\n")
        @loghandle.close
      end
      @@total_downloaded_filecount += @dlcount
      Logger.putline("=== statistics for /r/#{@subreddit}:")
      Logger.putline("=== downloaded #{@dlcount} images")
      Logger.putline("=== total retrieved files: #{@@total_downloaded_filecount}")
      Logger.putline("=== total retrieved data: #{Filesize.new(@@total_downloaded_filebytes).pretty}")
      writecache
    end
  end
end

def failopt_if(opt, msg, boolexpr)
  if boolexpr then
    $stderr.printf("error parsing option '--%s': %s\n", opt, msg)
    exit(1)
  end
end

def kvopt_deparse(str)
  if str.include?(":") then
    key, *rest = str.split(":")
    key.strip!
    val = rest.join(":")
    if (key.empty? || val.empty?) || (not key.match(/[a-z0-9_]/i)) then
      return nil
    end
    return [key.to_sym, val]
  end
  return nil
end

def kvopt_makevalue(key, rawval, opts)
  if opts.key?(key) then
    if opts[key].is_a?(Numeric) then
      return rawval.to_i
    end
  end
  return rawval
end

begin
  opts = Util.get_local_config(DEFAULT_CONFIG_VALUES)
  prs = OptionParser.new{|prs|
    prs.on("-d<val>", "--logfile=<val>", "write log to <val> instead of 'log_<subreddit>.log' (can be templated with '%s')"){|v|
      opts[:logfile] = v
    }
    prs.on("--outputdir=<val>", "set output directory.. default is './r_<subredditname>' (can be templated with '%s')"){|v|
      opts[:outputdir] = v
    }
    prs.on("--maxpages=<val>", "Maximum pages to fetch (note: values over 10 may not work!)"){|v|
      opts[:maxpages] = v.to_i
    }
    prs.on("--filesize=<val>", "Maximum filesize for images"){|v|
      opts[:filesize] = v.to_i
    }
    prs.on("--limit=<val>", "How many links to fetch per page. Maximum value is 100"){|v|
      opts[:limit] = v.to_i
    }
    prs.on("--section=<val>", "What to download. options are 'new', 'hot', 'top', and 'controversial'."){|v|
      opts[:section] = v
    }
    prs.on("--time=<val>", "From which timespan to download. options are 'day', 'week', 'month', 'year', and 'all'."){|v|
      opts[:time] = v
    }
    prs.on("--template=<val>", "file naming template string. use '--templatehelp' for more info"){|v|
      opts[:template] = v
    }
    prs.on("--redditusername=<val>", "Your reddit username - overrides 'REDDPICS_USERNAME'"){|v|
      opts[:redditusername] = v
    }
    prs.on("--redditpassword=<val>", "Your reddit password - overrides 'REDDPICS_PASSWORD'"){|v|
      opts[:redditpassword] = v
    }
    prs.on("--redditapikey=<val>", "Your API key - overrides 'REDDPICS_APIKEY'"){|v|
      opts[:redditapikey] = v
    }
    prs.on("--redditappid=<val>", "Your API appid - overrides 'REDDPICS_APPID'"){|v|
      opts[:redditappid] = v
    }
    prs.on("--timeout=<n>", "timeout after <n> seconds (sets 'tm_connect', 'tm_read', 'tm_write')"){|v|
      tv = v.to_i
      [:tm_connect, :tm_read, :tm_write].each do |name|
        opts[name] = tv
      end
    }
    prs.on("-w", "--[no-]converttowebp", "convert downloaded file to .webp (to reduce size significantly)"){|v|
      opts[:converttowebp] = v
    }
    prs.on("-x<key>:<value>", "--set=<key>:<value>", "set a raw named option. use '--dumpopts' to see available options"){|s|
      if (dt = kvopt_deparse(s)) != nil then
        k, v = dt
        opts[k] = kvopt_makevalue(k, v, opts)
      else
        $stderr.printf("error: failed to parse %p. expected format: <key> \":\" <value> (i.e., \"-xfilesize:10MB\")\n")
      end
    }
    prs.on("--dumpopts", "dumps available options for '-x'"){|_|
      $stderr.printf("options:\n")
      opts.each do |k, v|
        $stderr.printf("%15s: %p\n", k.to_s, v)
      end
      exit(0)
    }
    prs.on("-#", "--apihelp", "Prints a quick'n'dirty explanation how to get your API credentials"){|v|
      puts(APIHELPSTRING)
      exit(0)
    }
    prs.on("--templatehelp", "show information regarding templates"){|_|
      puts(
        "Filename template to use when downloading files. extension is automatically added.\n" +
        "album indexes are added regardless of the template chosen.\n" +
        "valid variables:\n" +
        "  %{name}     - the extracted filename, minus file extension\n" +
        "  %{title}    - the cleaned up title of the thread\n" +
        "  %{id}       - reddit thread id (i.e., http://reddit.com/r/subreddit/comments/<id>/...)\n" +
        "  %{username} - reddit username ('deleted' when user deleted their account)\n" +
        "  %{score}    - votes score\n" +
        "  %{created}  - UNIX timestamp at which time the link was submitted\n" +
        ""
      )
      exit(0)
    }
  }
  prs.parse!
  if ARGV.size > 0 then
    actualargv = []
    ARGV.each do |farg|
      arg = farg.dup
      arg.gsub!(/\//, "") while arg.match(/\//)
      if File.file?(arg) then
        $stderr.printf("ERROR:\n")
        $stderr.printf("subreddit argument %p also exists as a file in the current working directory\n", arg)
        $stderr.printf("please delete it, or change into a different directory!\n")
      else
        actualargv.push(arg)
      end
    end
    failopt_if(:limit,        "must be less than 100", opts[:limit] > 100)
    failopt_if(:maxpages,     "value must be larger than zero", opts[:maxpages] == 0)
    failopt_if(:redditapikey, "must be set (try '--apihelp')", (not opts[:redditapikey]))
    failopt_if(:time,         "uses an invalid timespan", (not opts[:time].match(/^(day|week|month|year|all)$/)))
    failopt_if(:filesize,     "must have a proper size suffix", (not opts[:filesize].match(/^\d+[kmgtpezy]b$/i)))
    actualargv.each do |subreddit|
      instanceopts = opts.dup
      if opts[:outputdir] then
        if opts[:outputdir].match(/%s/) then
          # instead of using sprintf, use String#% and %{whatever} notion?
          instanceopts[:outputdir] = sprintf(opts[:outputdir], subreddit)
        end
      else
        instanceopts[:outputdir] = subreddit
      end
      String.disable_colorization(true) if not $stderr.tty?
      ReddPics.new(subreddit, instanceopts)
    end
  else
    puts("usage: #{File.basename $0} <subreddit> [ -o <destination-folder> [... <other options>]]")
    puts("try #{File.basename $0} --help for other options")
  end
end

