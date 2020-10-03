package LANraragi::Model::Plugins;

use strict;
use warnings;
use utf8;
use feature 'fc';

use Redis;
use Encode;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::UserAgent;
use Data::Dumper;

use LANraragi::Utils::Generic qw(remove_spaces remove_newlines);
use LANraragi::Utils::Archive qw(extract_thumbnail);
use LANraragi::Utils::Logging qw(get_logger);

# Sub used by Auto-Plugin.
sub exec_enabled_plugins_on_file {

    my $id     = shift;
    my $logger = get_logger( "Auto-Plugin", "lanraragi" );

    $logger->info("Executing enabled metadata plugins on archive with id $id.");

    my $successes = 0;
    my $failures  = 0;
    my $addedtags = 0;

    my @plugins = LANraragi::Utils::Plugins::get_enabled_plugins("metadata");

    foreach my $pluginfo (@plugins) {
        my $name   = $pluginfo->{namespace};
        my @args   = LANraragi::Utils::Plugins::get_plugin_parameters($name);
        my $plugin = LANraragi::Utils::Plugins::get_plugin($name);
        my %plugin_result;

        #Every plugin execution is eval'd separately
        eval { %plugin_result = exec_metadata_plugin( $plugin, $id, "", @args ); };

        if ($@) {
            $failures++;
            $logger->error("$@");
        } elsif ( exists $plugin_result{error} ) {
            $failures++;
            $logger->error( $plugin_result{error} );
        } else {
            $successes++;
        }

        #If the plugin exec returned metadata, add it
        unless ( exists $plugin_result{error} ) {
            LANraragi::Utils::Database::add_tags( $id, $plugin_result{new_tags} );

            # Sum up all the added tags for later reporting.
            # This doesn't take into account tags that are added twice
            # (e.g by different plugins), but since this is more meant to show
            # if the plugins added any data at all it's fine.
            my @added_tags = split( ',', $plugin_result{new_tags} );
            $addedtags += @added_tags;

            if ( exists $plugin_result{title} ) {
                LANraragi::Utils::Database::set_title( $id, $plugin_result{title} );

                # Increment added_tags if the title changed as well
                $addedtags++;
            }
        }
    }

    return ( $successes, $failures, $addedtags );
}

# Unlike the two other methods, exec_login_plugin takes a plugin name and does the Redis lookup itself.
# Might be worth consolidating this later.
sub exec_login_plugin {
    my $plugname = shift;
    my $ua       = Mojo::UserAgent->new;
    my $logger   = get_logger( "Plugin System", "lanraragi" );

    if ($plugname) {
        $logger->debug("Calling matching login plugin $plugname.");
        my $loginplugin = LANraragi::Utils::Plugins::get_plugin($plugname);
        my @loginargs   = LANraragi::Utils::Plugins::get_plugin_parameters($plugname);

        if ( $loginplugin->can('do_login') ) {
            my $loggedinua = $loginplugin->do_login(@loginargs);

            if ( ref($loggedinua) eq "Mojo::UserAgent" ) {
                return $loggedinua;
            } else {
                $logger->error("Plugin did not return a Mojo::UserAgent object!");
            }
        } else {
            $logger->error("Plugin doesn't implement do_login!");
        }
    } else {
        $logger->info("No login plugin specified, returning empty UserAgent.");
    }

    return $ua;
}

sub exec_script_plugin {

    my ( $plugin, $input, @settings ) = @_;
    my $logger = get_logger( "Plugin System", "lanraragi" );

    #If the plugin has the method "get_tags",
    #catch all the required data and feed it to the plugin
    if ( $plugin->can('run_script') ) {

        my %pluginfo = $plugin->plugin_info();
        my $ua       = exec_login_plugin( $pluginfo{login_from} );

        # Bundle all the potentially interesting info in a hash
        my %infohash = (
            user_agent    => $ua,
            oneshot_param => $input
        );

        # Scripts don't have any predefined metadata in their spec so they're just ran as-is.
        # They can return whatever the heck they want in their hash as well, they'll just be shown as-is in the API output.
        my %result = $plugin->run_script( \%infohash, @settings );
        return %result;
    }
    return ( error => "Plugin doesn't implement run_script despite having a 'script' type." );
}

# Execute a specified plugin on a file, described through its Redis ID.
sub exec_metadata_plugin {

    my ( $plugin, $id, $oneshotarg, @args ) = @_;
    my $logger = get_logger( "Plugin System", "lanraragi" );

    if ( $id eq 0 ) {
        return ( error => "Tried to call a metadata plugin without providing an id." );
    }

    #If the plugin has the method "get_tags",
    #catch all the required data and feed it to the plugin
    if ( $plugin->can('get_tags') ) {

        my $redis = LANraragi::Model::Config->get_redis;
        my %hash  = $redis->hgetall($id);

        my ( $name, $title, $tags, $file, $thumbhash ) = @hash{qw(name title tags file thumbhash)};

        ( $_ = LANraragi::Utils::Database::redis_decode($_) ) for ( $name, $title, $tags );

        # If the thumbnail hash is empty or undefined, we'll generate it here.
        unless ( length $thumbhash ) {
            $logger->info("Thumbnail hash invalid, regenerating.");
            my $dirname = LANraragi::Model::Config->get_userdir;

            #eval the thumbnail extraction as it can error out and die
            eval { extract_thumbnail( $dirname, $id ) };
            if ($@) {
                $logger->warn("Error building thumbnail: $@");
                $thumbhash = "";
            } else {
                $thumbhash = $redis->hget( $id, "thumbhash" );
                $thumbhash = LANraragi::Utils::Database::redis_decode($thumbhash);
            }
        }
        $redis->quit();

        # Hand it off to the plugin here.
        # If the plugin requires a login, execute that first to get a UserAgent
        my %pluginfo = $plugin->plugin_info();
        my $ua       = exec_login_plugin( $pluginfo{login_from} );

        # Bundle all the potentially interesting info in a hash
        my %infohash = (
            archive_title  => $title,
            existing_tags  => $tags,
            thumbnail_hash => $thumbhash,
            file_path      => $file,
            user_agent     => $ua,
            oneshot_param  => $oneshotarg
        );

        my %newmetadata = $plugin->get_tags( \%infohash, @args );

        #Error checking
        if ( exists $newmetadata{error} ) {

            #Return the hash as-is.
            #It already has an "error" key, which will be read by the client.
            #No need for more processing.
            return %newmetadata;
        }

        my @tagarray = split( ",", $newmetadata{tags} );
        my $newtags  = "";

        #Process new metadata,
        #stripping out blacklisted tags and tags that we already have in Redis
        my $blist       = LANraragi::Model::Config->get_tagblacklist;
        my $blistenable = LANraragi::Model::Config->enable_blacklst;
        my @blacklist   = split( ',', $blist );                         # array-ize the blacklist string

        foreach my $tagtoadd (@tagarray) {

            remove_spaces($tagtoadd);
            remove_newlines($tagtoadd);

            unless ( index( uc($tags), uc($tagtoadd) ) != -1 ) {

                #Only proceed if the tag isnt already in redis
                my $good = 1;

                if ($blistenable) {
                    foreach my $black (@blacklist) {
                        remove_spaces($black);

                        if ( index( uc($tagtoadd), uc($black) ) != -1 ) {
                            $logger->info("Tag $tagtoadd is blacklisted, not adding.");
                            $good = 0;
                        }
                    }
                }

                if ($good) {

                    #This tag is processed and good to go
                    $newtags .= " $tagtoadd,";
                }
            }
        }

        #Strip last comma and return processed tags in a hash
        chop($newtags);
        my %returnhash = ( new_tags => $newtags );

        #Indicate a title change, if the plugin reports one
        if ( exists $newmetadata{title} ) {

            my $newtitle = $newmetadata{title};
            remove_spaces($newtitle);
            $returnhash{title} = $newtitle;
        }
        return %returnhash;
    }
    return ( error => "Plugin doesn't implement get_tags despite having a 'metadata' type." );
}

1;