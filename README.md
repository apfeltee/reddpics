
Reddpics is a commandline Subreddit image downloader, traversing subreddit pages, and downloading images (if any).  
Needs a valid API key and client id; see https://www.reddit.com/wiki/api how get both (don't worry, it's easy).  
Once you have those, create `~/.config/reddpics-login.sh`, with the following contents (you need to modify the values, obviously):

    export REDDPICS_APPID="<your-app-id>"
    export REDDPICS_APIKEY="<your-api-key>"
    export REDDPICS_USERNAME="<your-reddit-username>"
    export REDDPICS_PASSWORD="<your-reddit-password>"

Include this file in your `~/.bashrc` (or whichever shell you use), type `exec bash`, and you're pretty much good to go.

----

Since reddpics uses httprb, redd, and trollop, you need to install them before you can use it:  

    gem install http redd trollop

After that, usage is as simple as it gets:

    # download all hot images from /r/aww

All supported options:

    -o, --outputdir=<s>    Output directory to download images to. default is './r_<subredditname>'
    -m, --maxpages=<i>     Maximum pages to fetch (note: values over 10 may not work!) (default: 10)
    -l, --limit=<i>        How many links to fetch per page. Maximum value is 100 (default is 100) (default: 100)
    -s, --section=<s>      What to download. options are 'hot', 'top', and 'controversial'. default is 'top' (default: top)
    -t, --time=<s>         From which timespan to download. options are day, week, month, year, and all. default is all (default: all)
    -u, --username=<s>     Your reddit username - overrides 'REDDPICS_USERNAME'
    -p, --password=<s>     Your reddit password - overrides 'REDDPICS_PASSWORD'
    -a, --apikey=<s>       Your API key - overrides 'REDDPICS_APIKEY'
    -i, --appid=<s>        Your API appid - overrides 'REDDPICS_APPID'