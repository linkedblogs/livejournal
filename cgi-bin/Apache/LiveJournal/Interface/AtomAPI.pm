# AtomAPI support for LJ

package Apache::LiveJournal::Interface::AtomAPI;

use strict;
use Apache::Constants qw(:common);
use Digest::SHA1;
use MIME::Base64;
use XML::Atom::Entry;
use lib "$ENV{'LJHOME'}/cgi-bin";
require 'parsefeed.pl';

sub respond {
    my ($r, $status, $body, $type) = @_;

    my %msgs = (
        200 => 'OK',
        201 => 'Created',

        400 => 'Bad Request',
        401 => 'Authentication Failed',
        403 => 'Forbidden',
        404 => 'Not Found',
        500 => 'Server Error',
    ),

    my %mime = (
        html => 'text/html',
        atom => 'application/x.atom+xml',
        xml  => "text/xml; charset='utf-8'",
    );

    # if the passed in body was a reference, send it
    # without any modification.  otherwise, send some
    # prettier html to the client.
    my $out;
    if (ref $body) {
        $out = $$body;
    } else {
        $out = <<HTML;
<html><head><title>$status $msgs{$status}</title></head><body>
<h1>$msgs{$status}</h1><p>$body</p>
</body></html>
HTML
    }

    $type = $mime{$type} || 'text/html';
    $r->status_line("$status $msgs{$status}");
    $r->content_type($type);
    $r->send_http_header();
    $r->print($out);
    return OK;
};

sub handle_post {
    my ($r, $remote, $u, $opts) = @_;

    # read the content
    my $buff;
    $r->read($buff, $r->header_in("Content-length"));

    # try parsing it
    my $entry;
    eval { $entry = XML::Atom::Entry->new( \$buff ); };
    return respond($r, 400, "Could not parse the entry due to invalid markup.<br /><pre>$@</pre>")
        if $@;

    # on post, the entry must NOT include an id
    return respond($r, 400, "Must not include an <b>&lt;id&gt;</b> field in a new entry.")
        if $entry->id();

    # remove the SvUTF8 flag. See same code in synsuck.pl for
    # an explanation
    $entry->title( pack('C*', unpack('C*', $entry->title())) );
    $entry->link( pack('C*', unpack('C*', $entry->link())) );
    $entry->content( pack('C*', unpack('C*', $entry->content()->body())) );

    # build a post event request.
    my $req = {
        'usejournal'  => ( $remote->{'userid'} != $u->{'userid'} ) ? $u->{'user'} : undef,
        'ver'         => 1,
        'username'    => $u->{'user'},
        'lineendings' => 'unix',
        'subject'     => $entry->title(),
        'event'       => $entry->content()->body(),
        'props'       => {},
        'security'    => 'public',
        'tz'          => 'guess',
    };

    my $err;
    my $res = LJ::Protocol::do_request("postevent", 
                                       $req, \$err, { 'noauth' => 1 });

    if ($err) {
        my $errstr = LJ::Protocol::error_message($err);
        return respond($r, 500, "Unable to post new entry. Protocol error: <b>$errstr</b>.");
    }

    my $new_link = "$LJ::SITEROOT/interface/atom/edit/$res->{'itemid'}";
    $r->header_out("Location", $new_link);
    return respond($r, 201, \$entry->as_xml(), 'atom');
}

sub handle_edit {
    my ($r, $remote, $u, $opts) = @_;

    my $method = $opts->{'method'};

    # first, try to load the item and fail if it's not there
    my $jitemid = $opts->{'param'};
    my $req = {
        'usejournal' => ($remote->{'userid'} != $u->{'userid'}) ?
            $u->{'user'} : undef,
         'ver' => 1,
         'username' => $u->{'user'},
         'selecttype' => 'one',
         'itemid' => $jitemid,
    };

    my $err;
    my $olditem = LJ::Protocol::do_request("getevents", 
                                           $req, \$err, { 'noauth' => 1 });
    
    if ($err) {
        my $errstr = LJ::Protocol::error_message($err);
        return respond($r, 404, "Unable to retrieve the item requested for editing. Protocol error: <b>$errstr</b>.");
    }
    $olditem = $olditem->{'events'}->[0];

    if ($method eq "GET") {
        # return an AtomEntry for this item
        # use the interface between make_feed and create_view_atom in
        # ljfeed.pl

        # get the log2 row (need logtime for createtime)
        my $row = LJ::get_log2_row($u, $jitemid) ||
            return respond($r, 404, "Could not load the original entry.");

        # we need to put into $item: itemid, ditemid, subject, event, 
        # createtime, eventtime, modtime
        
        my $ctime = LJ::mysqldate_to_time($row->{'logtime'}, 1);

        my $item = {
            'itemid'     => $olditem->{'itemid'},
            'ditemid'    => $olditem->{'itemid'}*256 + $olditem->{'anum'},
            'eventtime'  => LJ::alldatepart_s2($row->{'eventtime'}),
            'createtime' => $ctime,
            'modtime'    => $olditem->{'props'}->{'revtime'} || $ctime,
            'subject'    => LJ::exml($olditem->{'subject'}),
            'event'      => LJ::exml($olditem->{'event'}),
        };

        my $ret = LJ::Feed::create_view_atom(
            { 'u' => $u },
            $u,
            {
                'noheader'   => 1,
                'saycharset' => "utf-8",
                'noheader'   => 1,
                'apilinks'   => 1,
            },
            [$item]
        );

        return respond($r, 200, \$ret, 'xml');
    }

    if ($method eq "PUT") {
        # read the content
        my $buff;
        $r->read($buff, $r->header_in("Content-length"));

        # try parsing it
        my $entry;
        eval { $entry = XML::Atom::Entry->new( \$buff ); };
        return respond($r, 400, "Could not parse the entry due to invalid markup.<br /><pre>$@</pre>")
            if $@;

        # remove the SvUTF8 flag. See same code in synsuck.pl for
        # an explanation
        $entry->title( pack('C*', unpack('C*', $entry->title())) );
        $entry->link( pack('C*', unpack('C*', $entry->link())) );
        $entry->content( pack('C*', unpack('C*', $entry->content()->body())) );

        # the AtomEntry must include <id> which must match the one we sent
        # on GET
        unless ($entry->id() =~ m#atom1:$u->{'user'}:(\d+)$# &&
                $1 == $olditem->{'itemid'}*256 + $olditem->{'anum'}) {
            return respond($r, 400, "Incorrect <b>&lt;id&gt;</b> field in this request.");
        }

        # build an edit event request. Preserve fields that aren't being
        # changed by this item (perhaps the AtomEntry isn't carrying the
        # complete information).
        
        $req = {
            'usejournal'  => ( $remote->{'userid'} != $u->{'userid'} ) ? $u->{'user'} : undef,
            'ver'         => 1,
            'username'    => $u->{'user'},
            'itemid'      => $jitemid,
            'lineendings' => 'unix',
            'subject'     => $entry->title() || $olditem->{'subject'},
            'event'       => $entry->content()->body() || $olditem->{'event'},
            'props'       => $olditem->{'props'},
            'security'    => $olditem->{'security'},
            'allowmask'   => $olditem->{'allowmask'},
        };

        $err = undef;
        my $res = LJ::Protocol::do_request("editevent", 
                                           $req, \$err, { 'noauth' => 1 });
    
        if ($err) {
            my $errstr = LJ::Protocol::error_message($err);
            return respond($r, 500, "Unable to update entry. Protocol error: <b>$errstr</b>.");
        }

        return respond($r, 200, "The entry was successfully updated.");
    }

    if ($method eq "DELETE") {
        
        # build an edit event request to delete the entry.
        
        $req = {
            'usejournal' => ($remote->{'userid'} != $u->{'userid'}) ?
                $u->{'user'}:undef,
            'ver' => 1,
            'username' => $u->{'user'},
            'itemid' => $jitemid,
            'lineendings' => 'unix',
            'event' => '',
        };

        $err = undef;
        my $res = LJ::Protocol::do_request("editevent", 
                                           $req, \$err, { 'noauth' => 1 });
    
        if ($err) {
            my $errstr = LJ::Protocol::error_message($err);
            return respond($r, 500, "Unable to delete entry. Protocol error: <b>$errstr</b>.");
        }

        return respond($r, 200, "Entry successfully deleted.");
    }
    
}

sub handle_feed {
    my ($r, $remote, $u, $opts) = @_;

    # simulate a call to the S1 data view creator, with appropriate
    # options
    
    my %op = ('pathextra' => "/atom",
              'saycharset'=> "utf-8",
              'apilinks'  => 1,
              );
    my $ret = LJ::Feed::make_feed($r, $u, $remote, \%op);

    unless (defined $ret) {
        if ($op{'redir'}) {
            # this happens if the account was renamed or a syn account.
            # the redir URL is wrong because ljfeed.pl is too 
            # dataview-specific. Since this is an admin interface, we can
            # just fail.
            return respond ($r, 404, "The account <b>$u->{'user'} </b> is of a wrong type and does not allow AtomAPI administration.");
        }
        if ($op{'handler_return'}) {
            # this could be a conditional GET shortcut, honor it
            $r->status($op{'handler_return'});
            return OK;
        }
        # should never get here
        return respond ($r, 404, "Unknown error.");
    }

    # everything's fine, return the XML body with the correct content type
    return respond($r, 200, \$ret, 'xml');

}

# this routine accepts the apache request handle, performs
# authentication, calls the appropriate method handler, and
# prints the response.
sub handle {
    my $r = shift;

    # break the uri down: /interface/atom/<verb>[/<number>]
    my ( $action, $param, $oldparam ) = ( $1, $2, $3 )
      if $r->uri =~ m#^/interface/atom(?:api)?/?(\w+)?(?:/(\w+))?(?:/(\d+))?$#;

    my $valid_actions = qr{feed|edit|post};

    # old uri was was: /interface/atomapi/<username>/<verb>[/<number>]
    # support both by shifting params around if we see something extra.
    if ($action !~ /$valid_actions/ && $r->uri =~ /atomapi/ ) {
        $action = $param;
        $param  = $oldparam;
    }

    # let's authenticate.
    # 
    # if wsse information is supplied, use it. 
    # if not, fall back to digest.
    my $wsse = $r->header_in('X-WSSE');
    my $u = $wsse ? auth_wsse($wsse) : LJ::auth_digest($r);
    return respond( $r, 401, "Authentication failed for this AtomAPI request.")
        unless $u;

    # service autodiscovery
    my $method = $r->method;
    if ( $method eq 'GET' && ! $action ) {
        LJ::load_user_props( $u, 'journaltitle' );
        my $title = $u->{journaltitle};
        my $ret = "<?xml version=\"1.0\"?>\n<feed xmlns=\"http://purl.org/atom/ns#\">\n";
        $ret .=
"\t<link type=\"application/x.atom+xml\" rel=\"service.$_\" href=\"$LJ::SITEROOT/interface/atom/$_\" title=\"$title\"/>\n"
          foreach qw/ post feed /;  # need to add upload, categories
        $ret .= "\t<link type=\"text/html\" rel=\"alternate\" href=\"$LJ::SITEROOT/users/$u->{user}/\" title=\"$title\"/>\n";
        $ret .= "</feed>\n";
        return respond($r, 200, \$ret, 'atom');
    }

    $action =~ /$valid_actions/
      or return respond($r, 400, "Unknown URI scheme: /interface/atom/<b>$action</b>");

    unless (($action eq 'feed' and $method eq 'GET') or
            ($action eq 'post' and $method eq 'POST') or
            ($action eq 'edit' and 
             {'GET'=>1,'PUT'=>1,'DELETE'=>1}->{$method})) {
        return respond($r, 400, "URI scheme /interface/atom/<b>$action</b> is incompatible with request method <b>$method</b>.");
    }

    if (($action ne 'edit' && $param) or
        ($action eq 'edit' && $param !~ m#^\d+$#)) {
        return respond($r, 400, "Either the URI lacks a required parameter, or its format is improper.");
    }

    # we've authenticated successfully and remote is set. But can remote
    # manage the requested account?
    my $remote = LJ::get_remote();
    unless (LJ::can_manage($remote, $u)) {
        return respond($r, 403, "User <b>$remote->{'user'}</b> has no administrative access to account <b>$u->{user}</b>.");
    }

    # handle the requested action
    my $opts = {
        'action' => $action,
        'method' => $method,
        'param'  => $param
    };

    {
        'feed' => \&handle_feed,
        'post' => \&handle_post,
        'edit' => \&handle_edit
    }->{$action}->( $r, $remote, $u, $opts );

    return OK;
}

# Authenticate via the WSSE header.
# Returns valid $u on success, undef on failure.
sub auth_wsse
{
    my $wsse = shift;
    $wsse =~ s/UsernameToken // or return undef;

    # parse credentials into a hash.
    my %creds;
    foreach (split /, /, $wsse) {
        my ($k, $v) = split '=', $_, 2;
        $v =~ s/^['"]//;
        $v =~ s/['"]$//;
        $v =~ s/=$// if $k =~ /passworddigest/i; # strip base64 newline char
        $creds{ lc($k) } = $v;
    }

    # invalid create time?  invalid wsse.
    my $ctime = LJ::ParseFeed::w3cdtf_to_time( $creds{created} ) or return undef;

    # prevent replay attacks.
    # 3 min windows on creation times / nonces
    $ctime = LJ::mysqldate_to_time( $ctime );
    return undef if time() - $ctime > 180;
    if (@LJ::MEMCACHE_SERVERS) {
        LJ::MemCache::add( "wsse_auth:$creds{username}:$creds{nonce}", 1, 180 )
          or return undef;
    }

    my $u = LJ::load_user( LJ::canonical_username( $creds{'username'} ) )
      or return undef;

    # validate hash
    my $hash =
      Digest::SHA1::sha1_base64(
        $creds{nonce} . $creds{created} . $u->{password} );

    # Nokia's WSSE implementation is incorrect as of 1.5, and they
    # base64 encode their nonce *value*.  If the initial comparison
    # fails, we need to try this as well before saying it's invalid.
    if ($hash ne $creds{passworddigest}) {

        $hash =
          Digest::SHA1::sha1_base64(
                MIME::Base64::decode_base64( $creds{nonce} ) .
                $creds{created} .
                $u->{password} );

        return undef if $hash ne $creds{passworddigest};
    }
    
    # If we're here, we're valid.
    LJ::set_remote($u);
    return $u;
}

1;
