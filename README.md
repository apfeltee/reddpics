
Reddpics is a commandline Subreddit image downloader, traversing subreddit pages, and downloading images (if any).  

You need a valid API key and client id; see https://www.reddit.com/wiki/api on how get both (don't worry, it's easy).  
Once you have those, create a configuration file at `~/.reddpics.cfg', with the following contents:

    # this is a YAML file (see http://yaml.org/).
    # lines starting with '#' are comments.

    # your reddit username
    redditusername: <your-username>
    # your reddit password
    redditpassword: <your-password>
    # the client ID of the app you've registered
    redditappid: <your-clientid>
    # the app secret of the app you've registered
    redditapikey: <your-appsecret>

    # these are for accessing things like imgur albums.
    # they aren't necessary for reddpics to function, but greatly enhance the amount
    # of images downloaded!
    # to register for an app id, visit https://api.imgur.com/oauth2/addclient
    # register as "anonymous usage" (since there is no website endpoint),
    # fill out the form, and finally, you'll have the necessary information.
    # then, uncomment the lines, and fill out the data.
    #imgurappid: <your-imgur-appid>
    #imgursecret: <your-imgur-appsecret>


Include this file in your `~/.bashrc` (or whichever shell you use), type `exec bash`, and you're pretty much good to go.  
If you're still not sure what to do, try 'reddpics --apihelp'.

----

# Features

  - Any URL whose 'Content-Type' header is that of an image (image/(jpeg|png|gif)), or webm (video/webm)
  - imgur pages (fairly complete)
  - gfycat links (fairly complete)
  - more to come, eventually

# Installation and Usage

Since reddpics uses some gems, you need to install them before you can use it:  

    gem install http redd trollop nokogiri colorize

After that, usage is as simple as it gets:

    # download the first 100 hot images from /r/aww to ./images/aww
    ./reddpics.rb aww --outputdir=./images/aww --limit=100 --maxpages=1 --section=hot

All supported options:

Usage: reddpics <subreddit ...> [<options>]
Valid options:

    -d, --logfile=<s>           if set, log will also be written to this file. as with '-o', you can use %s as template (default: log_%s.txt)
    -o, --outputdir=<s>         Output directory to download images to. default is './r_<subredditname>'.
                                You can use '%s' as template (for example, when downloading from several subreddits)
    -m, --maxpages=<i>          Maximum pages to fetch (note: values over 10 may not work!) (default: 10)
    -f, --filesize=<s>          Maximum filesize for images (default: 10MB)
    -l, --limit=<i>             How many links to fetch per page. Maximum value is 100 (default: 100)
    -s, --section=<s>           What to download. options are 'new', 'hot', 'top', and 'controversial'. (Default: top)
    -t, --time=<s>              From which timespan to download. options are 'day', 'week', 'month', 'year', and 'all'. (Default: all)
    -e, --template=<s>          Filename template to use when downloading files. extension is automatically added.
                                album indexes are added regardless of the template chosen.
                                valid variables:
                                  %{name}     - the extracted filename, minus file extension
                                  %{title}    - the cleaned up title of the thread
                                  %{id}       - reddit thread id (i.e., http://reddit.com/r/subreddit/comments/<id>/...)
                                  %{username} - reddit username ('deleted' when user deleted their account)
                                  %{score}    - votes score
                                  %{created}  - UNIX timestamp at which time the link was submitted
                                 (Default: %{title}-%{id})
    -r, --redditusername=<s>    Your reddit username - overrides 'REDDPICS_USERNAME'
    -i, --redditpassword=<s>    Your reddit password - overrides 'REDDPICS_PASSWORD'
    -a, --redditapikey=<s>      Your API key - overrides 'REDDPICS_APIKEY'
    -p, --redditappid=<s>       Your API appid - overrides 'REDDPICS_APPID'
    -#, --apihelp               Prints a quick'n'dirty explanation how to get your API credentials
    -h, --help                  Show this message
