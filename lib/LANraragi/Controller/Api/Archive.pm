package LANraragi::Controller::Api::Archive;
use Mojo::Base 'Mojolicious::Controller';

use Redis;
use Encode;
use Storable;
use Mojo::JSON qw(decode_json encode_json from_json);
use Scalar::Util qw(looks_like_number);

use LANraragi::Utils::Generic qw(render_api_response);
use LANraragi::Utils::Database;

use LANraragi::Model::Archive;
use LANraragi::Model::Category;
use LANraragi::Model::Config;
use LANraragi::Model::Reader;

# Archive API.

# Handle missing ID parameter for a whole lot of api methods down below.
sub check_id_parameter {
    my ( $mojo, $operation ) = @_;

    # Use either the id query param(deprecated), or the URL component.
    my $id = $mojo->req->param('id') || $mojo->stash('id') || 0;
    unless ($id) {
        render_api_response( $mojo, $operation, "No archive ID specified." );
    }
    return $id;
}

sub serve_archivelist {
    my $self   = shift;
    my @idlist = LANraragi::Model::Archive::generate_archive_list;
    $self->render( json => \@idlist );
}

sub serve_untagged_archivelist {
    my $self   = shift;
    my @idlist = LANraragi::Model::Archive::find_untagged_archives;
    $self->render( json => \@idlist );
}

sub serve_metadata {
    my $self  = shift;
    my $id    = check_id_parameter( $self, "metadata" ) || return;
    my $redis = $self->LRR_CONF->get_redis;

    my $arcdata = LANraragi::Utils::Database::build_archive_JSON( $redis, $id );
    $redis->quit;
    $self->render( json => $arcdata );
}

# Find which categories this ID is saved in.
sub get_categories {

    my $self = shift;
    my $id   = check_id_parameter( $self, "find_arc_categories" ) || return;

    my @categories = LANraragi::Model::Category->get_category_list;
    @categories = grep { %$_{"search"} eq "" } @categories;

    my @filteredcats = ();

    # Check if the id is in any categories
    for my $category (@categories) {

        my @archives = @{ $category->{"archives"} };

        if ( grep( /^$id$/, @archives ) ) {
            push @filteredcats, $category;
        }
    }

    $self->render(
        json => {
            operation  => "find_arc_categories",
            categories => \@filteredcats,
            success    => 1
        }
    );
}

sub serve_thumbnail {
    my $self = shift;
    my $id   = check_id_parameter( $self, "thumbnail" ) || return;
    LANraragi::Model::Archive::serve_thumbnail( $self, $id );
}

# Use RenderFile to get the file of the provided id to the client.
sub serve_file {

    my $self  = shift;
    my $id    = check_id_parameter( $self, "servefile" ) || return;
    my $redis = $self->LRR_CONF->get_redis();

    my $file = $redis->hget( $id, "file" );
    $redis->quit();
    $self->render_file( filepath => $file );
}

# Serve an archive page from the temporary folder, using RenderFile.
sub serve_page {
    my $self = shift;
    my $id   = check_id_parameter( $self, "serve_page" ) || return;
    my $path = $self->req->param('path') || "404.xyz";

    LANraragi::Model::Archive::serve_page( $self, $id, $path );
}

sub extract_archive {
    my $self = shift;
    my $id   = check_id_parameter( $self, "extract_archive" ) || return;
    my $readerjson;

    eval { $readerjson = LANraragi::Model::Reader::build_reader_JSON( $self, $id, "0", "0" ); };
    my $err = $@;

    if ($err) {
        render_api_response( $self, "extract_archive", $err );
    } else {
        $self->render( json => decode_json($readerjson) );
    }
}

sub clear_new {
    my $self = shift;
    my $id   = check_id_parameter( $self, "clear_new" ) || return;

    my $redis = $self->LRR_CONF->get_redis();

    # Just set isnew to false for the provided ID.
    if ( $redis->hget( $id, "isnew" ) ne "false" ) {

        # Bust search cache...partially!
        LANraragi::Utils::Database::invalidate_isnew_cache();

        $redis->hset( $id, "isnew", "false" );
    }
    $redis->quit();

    $self->render(
        json => {
            operation => "clear_new",
            id        => $id,
            success   => 1
        }
    );
}

sub delete_archive {
    my $self = shift;
    my $id   = check_id_parameter( $self, "delete_archive" ) || return;

    my $delStatus = LANraragi::Utils::Database::delete_archive($id);

    $self->render(
        json => {
            operation => "delete_archive",
            id        => $id,
            filename  => $delStatus,
            success   => $delStatus eq "0" ? 0 : 1
        }
    );
}

sub update_metadata {
    my $self = shift;
    my $id   = check_id_parameter( $self, "update_metadata" ) || return;

    my $title = $self->req->param('title') || undef;
    my $tags  = $self->req->param('tags')  || undef;

    my $res = LANraragi::Model::Archive::update_metadata( $id, $title, $tags );

    if ( $res eq "" ) {
        render_api_response( $self, "update_metadata" );
    } else {
        render_api_response( $self, "update_metadata", $res );
    }
}

sub update_progress {
    my $self = shift;
    my $id   = check_id_parameter( $self, "update_progress" ) || return;

    my $page = $self->stash('page') || 0;

    # Undocumented parameter to force progress update
    my $force = $self->req->param('force') || 0;

    my $redis     = $self->LRR_CONF->get_redis();
    my $pagecount = $redis->hget( $id, "pagecount" );

    if ( LANraragi::Model::Config->enable_localprogress ) {
        render_api_response( $self, "update_progress", "在此实例上禁用服务器端进度跟踪。" );
        return;
    }

    # This relies on pagecount, so you can't update progress for archives that don't have a valid pagecount recorded yet.
    unless ( $pagecount || $force ) {
        render_api_response( $self, "update_progress", "档案还没有记录的总页数。" );
        return;
    }

    # Safety-check the given page value.
    unless ( $force || ( looks_like_number($page) && $page > 0 && $page <= $pagecount ) ) {
        render_api_response( $self, "update_progress", "无效的进度值。" );
        return;
    }

    # Just set the progress value.
    $redis->hset( $id, "progress", $page );

    # Update total pages read statistic
    $redis->incr("LRR_TOTALPAGESTAT");

    $redis->quit();

    $self->render(
        json => {
            operation => "update_progress",
            id        => $id,
            page      => $page,
            success   => 1
        }
    );

}

1;
