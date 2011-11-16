#!/usr/bin/perl
#
# DW::Controller::Entry
#
# This controller is for the create entry page
#
# Authors:
#      Afuna <coder.dw@afunamatata.com>
#
# Copyright (c) 2011 by Dreamwidth Studios, LLC.
#
# This program is free software; you may redistribute it and/or modify it under
# the same terms as Perl itself. For a copy of the license, please reference
# 'perldoc perlartistic' or 'perldoc perlgpl'.
#

package DW::Controller::Entry;

use strict;

use DW::Controller;
use DW::Routing;
use DW::Template;

use Hash::MultiValue;
use HTTP::Status qw( :constants );


=head1 NAME

DW::Controller::Entry - Controller which handles posting and editing entries

=head1 Controller API

Handlers for creating and editing entries

=cut

DW::Routing->register_string( '/entry/new', \&new_handler, app => 1 );
DW::Routing->register_regex( '/entry/([^/]+)/new', \&new_handler, app => 1 );

DW::Routing->register_string( '/entry/preview', \&preview_handler, app => 1, methods => { POST => 1 } );

DW::Routing->register_string( '/entry/options', \&options_handler, app => 1, format => "html" );
DW::Routing->register_string( '/__rpc_entryoptions', \&options_rpc_handler, app => 1, format => "html" );

                             # /entry/username/ditemid/edit
#DW::Routing->register_regex( '^/entry/(?:(.+)/)?(\d+)/edit$', \&edit_handler, app => 1 );


=head2 C<< DW::Controller::Entry::new_handler( ) >>

Handles posting a new entry

=cut
sub new_handler {
    my ( $call_opts, $usejournal ) = @_;

    my $r = DW::Request->get;
    my $remote = LJ::get_remote();

    return error_ml( "/entry.tt.beta.off", { aopts => "href='$LJ::SITEROOT/betafeatures'" } )
        unless $remote && LJ::BetaFeatures->user_in_beta( $remote => "updatepage" );

    my @error_list;
    my @warnings;
    my $post;
    my %spellcheck;

    if ( $r->did_post ) {
        $post = $r->post_args;

        my $mode_preview = $post->{"action:preview"};
        my $mode_spellcheck = $post->{"action:spellcheck"};

        push @error_list, LJ::Lang::ml( 'bml.badinput.body' )
            unless LJ::text_in( $post );

        my $okay_formauth = ! $remote || LJ::check_form_auth( $post->{lj_form_auth} );

        # ... but see TODO below
        push @error_list, LJ::Lang::ml( "error.invalidform" )
            unless $okay_formauth;

        if ( $mode_preview ) {
            # do nothing
        } elsif ( $mode_spellcheck ) {
            if ( $LJ::SPELLER ) {
                my $spellchecker = LJ::SpellCheck-> new( {
                                    spellcommand => $LJ::SPELLER,
                                    class        => "searchhighlight",
                                } );
                my $event = $post->{event};
                $spellcheck{results} = $spellchecker->check_html( \$event, 1 );
                $spellcheck{did_spellcheck} = 1;
            }
        } elsif ( $okay_formauth && ! $post->{showform} # some other form posted content to us, which the user will want to edit further
        ) {
            my $flags = {};

            my %auth = _auth( $flags, $post, $remote );

            my $uj = $auth{journal};
            push @error_list, $LJ::MSG_READONLY_USER
                if $uj && $uj->readonly;

            # do a login action to check if we can authenticate as unverified_username
            # and to display any important messages connected to your account
            {
                # build a clientversion string
                my $clientversion = "Web/3.0.0";

                # build a request object
                my %login_req = (
                    ver             => $LJ::PROTOCOL_VER,
                    clientversion   => $clientversion,
                    username        => $auth{unverified_username},
                );

                my $err;
                my $login_res = LJ::Protocol::do_request( "login", \%login_req, \$err, $flags );

                unless ( $login_res ) {
                    push @error_list, LJ::Lang::ml( "/update.bml.error.login" )
                        . " " . LJ::Protocol::error_message( $err );
                }

                # e.g. not validated
                push @warnings, {   type => "info",
                                    message => LJ::auto_linkify( LJ::ehtml( $login_res->{message} ) )
                                } if $login_res->{message};
            }

            my $form_req = {};
            my %status = _decode( $form_req, $post );
            push @error_list, @{$status{errors}}
                if exists $status{errors};

            # if we didn't have any errors with decoding the form, proceed to post
            unless ( @error_list ) {
                my %post_res = _do_post( $form_req, $flags, \%auth, warnings => \@warnings );
                return $post_res{render} if $post_res{status} eq "ok";

                # oops errors when posting: show error, fall through to show form
                push @error_list, $post_res{errors} if $post_res{errors};
            }
        }
    }

    # figure out times
    my $datetime;
    my $trust_datetime_value = 0;

    if ( $post && $post->{entrytime} && $post->{entrytime_hr} && $post->{entrytime_min} ) {
        $datetime = "$post->{entrytime} $post->{entrytime_hr}:$post->{entrytime_min}";
        $trust_datetime_value = 1;
    } else {
        my $now = DateTime->now;

        # if user has timezone, use it!
        if ( $remote && $remote->prop( "timezone" ) ) {
            my $tz = $remote->prop( "timezone" );
            $tz = $tz ? eval { DateTime::TimeZone->new( name => $tz ); } : undef;
            $now = eval { DateTime->from_epoch( epoch => time(), time_zone => $tz ); }
               if $tz;
        }

        $datetime = $now->strftime( "%F %R" ),
        $trust_datetime_value = 0;  # may want to override with client-side JS
    }

    my $get = $r->get_args;
    $usejournal ||= $get->{usejournal};
    my $vars = init( {  usejournal  => $usejournal,
                        altlogin    => $get->{altlogin},
                        datetime    => $datetime || "",
                        trust_datetime_value => $trust_datetime_value,
                      }, @_ );

    # these kinds of errors prevent us from initiating the form at all
    # so abort and return it without the form
    return error_ml( $vars->{abort}, $vars->{args} )
        if $vars->{abort};


    # now look for errors that we still want to recover from
    push @error_list, LJ::Lang::ml( "/update.bml.error.invalidusejournal" )
        if defined $usejournal && ! $vars->{usejournal};

    # this is an error in the user-submitted data, so regenerate the form with the error message and previous values
    $vars->{error_list} = \@error_list if @error_list;
    $vars->{warnings} = \@warnings;

    $vars->{spellcheck} = \%spellcheck;

    # prepopulate if we haven't been through this form already
    $vars->{formdata} = $post || _prepopulate( $get );

    # we don't need this JS magic if we are sending everything over SSL
    unless ( $LJ::IS_SSL ) {
        $vars->{chalresp_js} = (! $LJ::REQ_HEAD_HAS{'chalresp_js'}++) ? $LJ::COMMON_CODE{'chalresp_js'} : "";
        $vars->{login_chal} = LJ::challenge_generate( 3600 ); # one hour to post if they're not logged in
    }

    $vars->{vclass} = [qw(
        midimal
        minimal
        maximal
    )]->[$get->{v}||0];
    $vars->{show_unimplemented} = $get->{highlight} ? 1 : 0;
    $vars->{betacommunity} = LJ::load_user( "dw_beta" );
    return DW::Template->render_template( 'entry.tt', $vars );
}


=head2 C<< DW::Controller::Entry::init( ) >>

Initializes entry form values.

Can be used when posting a new entry or editing an old entry. .

Arguments:
* form_opts: options for initializing the form
=over

=item altlogin      bool: whether we are posting as someone other than the currently logged in user
=item usejournal    string: username of the journal we're posting to (if not provided,
                        use journal of the user we're posting as)
=item datetime      string: display date of the entry in format "$year-$mon-$mday $hour:$min" (already taking into account timezones)

=back

* call_opts: instance of DW::Routing::CallInfo

=cut
sub init {
    my ( $form_opts, $call_opts ) = @_;

    my ( $ok, $rv ) = controller( anonymous => 1 );
    return $rv unless $ok;

    my $post_as_other = $form_opts->{altlogin} ? 1 : 0;
    my $u = $post_as_other ? undef : $rv->{remote};
    my $vars = {};

    my @icons;
    my $defaulticon;

    my %moodtheme;
    my @moodlist;
    my $moods = DW::Mood->get_moods;

    # we check whether the user can actually post to this journal on form submission
    # journal we explicitly say we want to post to
    my $usejournal = LJ::load_user( $form_opts->{usejournal} );
    my @journallist;
    push @journallist, $usejournal if LJ::isu( $usejournal );

    # the journal we are actually posting to (whether implicitly or overriden by usejournal)
    my $journalu = LJ::isu( $usejournal ) ? $usejournal : $u;

    my @crosspost_list;
    my $crosspost_main = 0;

    my $panels;
    my $formwidth;
    my $min_animation;
    if ( $u ) {
        return { abort => "/update.bml.error.nonusercantpost", args => { sitename => $LJ::SITENAME } }
            if $u->is_identity;

        return { abort => '/update.bml.error.cantpost' }
            unless $u->can_post;

        return { abort => '/update.bml.error.disabled' }
            if $u->can_post_disabled;


        # icons
        @icons = grep { ! ( $_->inactive || $_->expunged ) } LJ::Userpic->load_user_userpics( $u );
        @icons = LJ::Userpic->separate_keywords( \@icons )
            if @icons;

        $defaulticon = $u->userpic;


        # moods
        my $theme = DW::Mood->new( $u->{moodthemeid} );

        if ( $theme ) {
            $moodtheme{id} = $theme->id;
            foreach my $mood ( values %$moods )  {
                $theme->get_picture( $mood->{id}, \ my %pic );
                next unless keys %pic;

                $moodtheme{pics}->{$mood->{id}}->{pic} = $pic{pic};
                $moodtheme{pics}->{$mood->{id}}->{width} = $pic{w};
                $moodtheme{pics}->{$mood->{id}}->{height} = $pic{h};
                $moodtheme{pics}->{$mood->{id}}->{name} = $mood->{name};
            }
        }


        @journallist = ( $u, $u->posting_access_list )
            unless $usejournal;


        # crosspost
        my @accounts = DW::External::Account->get_external_accounts( $u );
        if ( scalar @accounts ) {
            foreach my $acct ( @accounts ) {
                my $selected;

                # FIXME: edit, spellcheck
                $selected = $acct->xpostbydefault;

                push @crosspost_list, {
                    id          => $acct->acctid,
                    name        => $acct->displayname,
                    selected    => $selected,
                    need_password => $acct->password ? 0 : 1,
                };

                $crosspost_main = 1 if $selected;
            }
        }

        $panels = $u->entryform_panels;
        $formwidth = $u->entryform_width;
        $min_animation = $u->prop( "js_animations_minimal" ) ? 1 : 0;
    }

    @moodlist = ( { id => "", name => LJ::Lang::ml( "entryform.mood.noneother" ) } );
    push @moodlist, { id => $_, name => $moods->{$_}->{name} }
        foreach sort { $moods->{$a}->{name} cmp $moods->{$b}->{name} } keys %$moods;

    my ( @security, @custom_groups );
    if ( $journalu && $journalu->is_community ) {
        @security = (
            { value => "public",  label => LJ::Lang::ml( 'label.security.public2' ) },
            { value => "access",  label => LJ::Lang::ml( 'label.security.members' ) },
            { value => "private", label => LJ::Lang::ml( 'label.security.maintainers' ) },
        );
    } else {
        @security = (
            { value => "public",  label => LJ::Lang::ml( 'label.security.public2' ) },
            { value => "access",  label => LJ::Lang::ml( 'label.security.accesslist' ) },
            { value => "private", label => LJ::Lang::ml( 'label.security.private2' ) },
        );

        if ( $u ) {
            @custom_groups = map { { value => $_->{groupnum}, label => $_->{groupname} } } $u->trust_groups;

            push @security, { value => "custom", label => LJ::Lang::ml( 'label.security.custom' ) }
                if @custom_groups;
        }
    }

    my ( $year, $mon, $mday, $hour, $min ) = split( /\D/, $form_opts->{datetime} || "" );
    my %displaydate;
    $displaydate{year}  = $year;
    $displaydate{month} = $mon;
    $displaydate{day}   = $mday;
    $displaydate{hour}  = $hour;
    $displaydate{minute}   = $min;

    $displaydate{trust_initial} = $form_opts->{trust_datetime_value};

# TODO:
#             # JavaScript sets this value, so we know that the time we get is correct
#             # but always trust the time if we've been through the form already
#             my $date_diff = ($opts->{'mode'} eq "edit" || $opts->{'spellcheck_html'}) ? 1 : 0;

    $vars = {
        remote => $u,

        icons       => @icons ? [ { userpic => $defaulticon }, @icons ] : [],
        defaulticon => $defaulticon,

        moodtheme => \%moodtheme,
        moods     => \@moodlist,

        journallist => \@journallist,
        usejournal  => $usejournal,
        post_as     => $form_opts->{altlogin} ? "other" : "remote",

        security     => \@security,
        customgroups => \@custom_groups,

        journalu    => $journalu,

        crosspost_entry => $crosspost_main,
        crosspostlist => \@crosspost_list,
        crosspost_url => "$LJ::SITEROOT/manage/settings/?cat=othersites",

        displaydate => \%displaydate,


        can_spellcheck => $LJ::SPELLER,

        panels      => $panels,
        formwidth   => $formwidth eq "P" ? "narrow" : "wide",
        min_animation => $min_animation ? 1 : 0,
    };

    return $vars;
}

=head2 C<< DW::Controller::Entry::edit_handler( ) >>

Handles generating the form for, and handling the actual edit of an entry

=cut
sub edit_handler {
    # FIXME: this needs careful handling for auth, but for right now let me just skip that altogether
    return _edit(@_);
}

# FIXME: remove
sub _edit {
    my ( $opts, $username, $ditemid ) = @_;
}

# returns:
# poster: user object that contains the poster of the entry. may be the current remote user,
#           or may be someone logging in via the login form on the entry
# journal: user object for the journal the entry is being posted to. may be the same as the
#           poster, or may be a community
# unverified_username: username that current remote is trying to post as; remote may not
#           actually have access to this journal so don't treat as trusted
#
# modifies/sets:
# flags: hashref of flags for the protocol
#   noauth = 1 if the user is the same as remote or has authenticated successfully
#   u = user we're posting as

sub _auth {
    my ( $flags, $post, $remote, $referer ) = @_;
    # referer only should be passed in if outside web context, such as when running tests

    my %auth;
    foreach ( qw( username chal response password ) ) {
        $auth{$_} = $post->{$_} || "";
    }
    $auth{post_as_other} = ( $post->{post_as} || "" ) eq "other" ? 1 : 0;

    my $user_is_remote = $remote && $remote->user eq $auth{username};
    my %ret;

    if ( $auth{username}            # user argument given
        && ! $user_is_remote        # user != remote
        && ( ! $remote || $auth{post_as_other} ) ) {  # user not logged in, or user is posting as other

        my $u = LJ::load_user( $auth{username} );

        my $ok;
        if ( $auth{response} ) {
            # verify entered password, if it is present
            $ok = LJ::challenge_check_login( $u, $auth{chal}, $auth{response} );
        } else {
            # js disabled, fallback to plaintext
            $ok = LJ::auth_okay( $u, $auth{password} );
        }

        if ( $ok ) {
            $flags->{noauth} = 1;
            $flags->{u} = $u;

            $ret{poster} = $u;
            $ret{journal} = $post->{postas_usejournal} ? LJ::load_user( $post->{postas_usejournal} ) : $u;
        }
    } elsif ( $remote && LJ::check_referer( undef, $referer ) ) {
        $flags->{noauth} = 1;
        $flags->{u} = $remote;

        $ret{poster} = $remote;
        $ret{journal} = $post->{usejournal} ? LJ::load_user( $post->{usejournal} ) : $remote;
    }

    $ret{unverified_username} = $ret{poster} ? $ret{poster}->username : $auth{username};
    return %ret;
}

# decodes the posted form into a hash suitable for use with the protocol
# $post is expected to be an instance of Hash::MultiValue
sub _decode {
    my ( $req, $post ) = @_;

    my @errors;

    # handle event subject and body
    $req->{subject} = $post->{subject};
    $req->{event} = $post->{event} || "";

    push @errors, LJ::Lang::ml( "/update.bml.error.noentry" )
        if $req->{event} eq "";


    # initialize props hash
    $req->{props} ||= {};
    my $props = $req->{props};

    my %mapped_props = (
        # currents / metadata
        current_mood        => "current_moodid",
        current_mood_other  => "current_mood",
        current_music       => "current_music",
        current_location    => "current_location",

        taglist             => "taglist",

        icon                => "picture_keyword",
    );
    while ( my ( $formname, $propname ) = each %mapped_props ) {
        $props->{$propname} = $post->{$formname}
            if defined $post->{$formname};
    }
    $props->{opt_backdated} = $post->{entrytime_outoforder} ? 1 : 0;
    # FIXME
    $props->{opt_preformatted} = 0;
#     $req->{"prop_opt_preformatted"} ||= $POST->{'switched_rte_on'} ? 1 :
#         $POST->{event_format} && $POST->{event_format} eq "preformatted" ? 1 : 0;

    # old implementation of comments
    # FIXME: remove this before taking the page out of beta
    $props->{opt_screening}  = $post->{opt_screening};
    $props->{opt_nocomments} = $post->{comment_settings} && $post->{comment_settings} eq "nocomments" ? 1 : 0;
    $props->{opt_noemail}    = $post->{comment_settings} && $post->{comment_settings} eq "noemail" ? 1 : 0;


    # see if an "other" mood they typed in has an equivalent moodid
    if ( $props->{current_mood} ) {
        if ( my $moodid = DW::Mood->mood_id( $props->{current_mood} ) ) {
            $props->{current_moodid} = $moodid;
            delete $props->{current_mood};
        }
    }


    # nuke taglists that are just blank
    $props->{taglist} = "" unless $props->{taglist} && $props->{taglist} =~ /\S/;

    if ( LJ::is_enabled( 'adult_content' ) ) {
        $props->{adult_content} = {
            ''              => '',
            'none'          => 'none',
            'discretion'    => 'concepts',
            'restricted'    => 'explicit',
        }->{$post->{age_restriction}} || "";

        $props->{adult_content_reason} = $post->{age_restriction_reason} || "";
    }


    # entry security
    my $sec = "public";
    my $amask = 0;
    {
        my $security = $post->{security} || "";
        if ( $security eq "private" ) {
            $sec = "private";
        } elsif ( $security eq "access" ) {
            $sec = "usemask";
            $amask = 1;
        } elsif ( $security eq "custom" ) {
            $sec = "usemask";
            foreach my $bit ( $post->get_all( "custom_bit" ) ) {
                $amask |= (1 << $bit);
            }
        }
    }
    $req->{security} = $sec;
    $req->{allowmask} = $amask;


    # date/time
    my ( $year, $month, $day ) = split( /\D/, $post->{entrytime} || "" );
    my ( $hour, $min ) = ( $post->{entrytime_hr}, $post->{entrytime_min} );

    # if we trust_datetime, it's because we either are in a mode where we've saved the datetime before (e.g., edit)
    # or we have run the JS that syncs the datetime with the user's current time
    # we also have to trust the datetime when the user has JS disabled, because otherwise we won't have any fallback value
    if ( $post->{trust_datetime} || $post->{nojs} ) {
        delete $req->{tz};
        $req->{year}    = $year;
        $req->{mon}     = $month;
        $req->{day}     = $day;
        $req->{hour}    = $hour;
        $req->{min}     = $min;
    }

    # crosspost
    $req->{crosspost_entry} = $post->{crosspost_entry} ? 1 : 0;
    if ( $req->{crosspost_entry} ) {
        foreach my $acctid ( $post->get_all( "crosspost" ) ) {
            $req->{crosspost}->{$acctid} = {
                id          => $acctid,
                password    => $post->{"crosspost_password_$acctid"},
                chal        => $post->{"crosspost_chal_$acctid"},
                resp        => $post->{"crosspost_resp_$acctid"},
            };
        }
    }

    return ( errors => \@errors ) if @errors;

    return ();
}

sub _save_new_entry {
    my ( $form_req, $flags, $auth ) = @_;

    my $req = {
        ver         => $LJ::PROTOCOL_VER,
        username    => $auth->{poster} ? $auth->{poster}->user : undef,
        usejournal  => $auth->{journal} ? $auth->{journal}->user : undef,
        tz          => 'guess',
        xpost       => '0', # don't crosspost by default; we handle this ourselves later
        %$form_req
    };


    my $err = 0;
    my $res = LJ::Protocol::do_request( "postevent", $req, \$err, $flags );

    return { errors => LJ::Protocol::error_message( $err ) } unless $res;
    return $res;
}

sub _do_post {
    my ( $form_req, $flags, $auth, %opts ) = @_;

    my $res = _save_new_entry( $form_req, $flags, $auth );
    return %$res if $res->{errors};

    # post succeeded, time to do some housecleaning
    _persist_props( $auth->{poster}, $form_req );

    my $ret = "";
    my $render_ret;
    my @links;
    my @crossposts;

    # we may have warnings generated by previous parts of the process
    my @warnings = @{ $opts{warnings} || [] };

    # special-case moderated: no itemid, but have a message
    if ( ! defined $res->{itemid} && $res->{message} ) {
        $ret .= qq{<div class="message-box info-box"><p>$res->{message}</p></div>};
        $render_ret = DW::Template->render_template(
            'entry-success.tt', {
                poststatus  => $ret,
            }
        );

    } else {
        # e.g., bad HTML in the entry
        push @warnings, {   type => "warning",
                            message => LJ::auto_linkify( LJ::ehtml( $res->{message} ) )
                        } if $res->{message};

        my $u = $auth->{poster};
        my $ju = $auth->{journal} || $auth->{poster};


        # we updated successfully! Now tell the user
        my $update_ml = $ju->is_community ? "/update.bml.update.success2.community" : "/update.bml.update.success2";
        $ret .= LJ::Lang::ml( $update_ml, {
            aopts => "href='" . $ju->journal_base . "/'",
        } );



        # bunch of helpful links
        my $juser = $ju->user;
        my $ditemid = $res->{itemid} * 256 + $res->{anum};
        my $itemlink = $res->{url};
        my $edititemlink = "$LJ::SITEROOT/editjournal?journal=$juser&itemid=$ditemid";

        my @links = (
            { url => $itemlink,
                text => LJ::Lang::ml( "/update.bml.success.links.view" ) }
        );

        if ( $form_req->{props}->{opt_backdated} ) {
            # we have to do some gymnastics to figure out the entry date
            my $e = LJ::Entry->new_from_url( $itemlink );
            my ( $y, $m, $d ) = ( $e->{eventtime} =~ /^(\d+)-(\d+)-(\d+)/ );
            push @links, {
                url => $ju->journal_base . "/$y/$m/$d/",
                text => LJ::Lang::ml( "/update.bml.success.links.backdated" ),
            }
        }

        push @links, (
            { url => $edititemlink,
                text => LJ::Lang::ml( "/update.bml.success.links.edit" ) },
            { url => "$LJ::SITEROOT/tools/memadd?journal=$juser&itemid=$ditemid",
                text => LJ::Lang::ml( "/update.bml.success.links.memories" ) },
            { url => "$LJ::SITEROOT/edittags?journal=$juser&itemid=$ditemid",
                text => LJ::Lang::ml( "/update.bml.success.links.tags" ) },
        );


        # crosspost!
        my @crossposts;
        if ( $u->equals( $ju ) && $form_req->{crosspost_entry} ) {
            my $user_crosspost = $form_req->{crosspost};
            my ( $xpost_successes, $xpost_errors ) =
                LJ::Protocol::schedule_xposts( $u, $ditemid, 0,
                        sub {
                            my $submitted = $user_crosspost->{$_[0]->acctid} || {};

                            # first argument is true if user checked the box
                            # false otherwise
                            return ( $submitted->{id} ? 1 : 0,
                                {
                                    password => $submitted->{password},
                                    auth_challenge => $submitted->{chal},
                                    auth_response => $submitted->{resp},
                                }
                            );
                        } );

            foreach my $crosspost ( @{$xpost_successes||[]} ) {
                push @crossposts, { text => LJ::Lang::ml( "xpost.request.success2", {
                                                account => $crosspost->displayname,
                                                sitenameshort => $LJ::SITENAMESHORT,
                                            } ),
                                    status => "ok",
                                };
            }

            foreach my $crosspost( @{$xpost_errors||[]} ) {
                push @crossposts, { text => LJ::Lang::ml( 'xpost.request.failed', {
                                                    account => $crosspost->displayname,
                                                    editurl => $edititemlink,
                                                } ),
                                    status => "error",
                                 };
            }
        }

        $render_ret = DW::Template->render_template(
            'entry-success.tt', {
                poststatus  => $ret,        # did the update succeed or fail?
                warnings    => \@warnings,   # warnings about the entry or your account
                crossposts  => \@crossposts,# crosspost status list
                links       => \@links,
            }
        );
    }

    return ( status => "ok", render => $render_ret );
}

# remember value of properties, to use the next time the user makes a post
sub _persist_props {
    my ( $u, $form ) = @_;

    return unless $u;
# FIXME:
#
#                 # persist the default value of the disable auto-formatting option
#                 $u->disable_auto_formatting( $POST{event_format} ? 1 : 0 );
#
#                 # Clear out a draft
#                 $remote->set_prop('entry_draft', '')
#                     if $remote;
#
#                 # Store what editor they last used
#                 unless (!$remote || $remote->prop('entry_editor') =~ /^always_/) {
#                      $POST{'switched_rte_on'} ?
#                          $remote->set_prop('entry_editor', 'rich') :
#                          $remote->set_prop('entry_editor', 'plain');
#                  }

}

sub _prepopulate {
    my $get = $_[0];

    my $subject = $get->{subject};
    my $event   = $get->{event};
    my $tags    = $get->{tags};

    # if a share url was passed in, fill in the fields with the appropriate text
    if ( $get->{share} ) {
        eval "use DW::External::Page; 1;";
        if ( ! $@ && ( my $page = DW::External::Page->new( url => $get->{share} ) ) ) {
            $subject = LJ::ehtml( $page->title );
            $event = '<a href="' . $page->url . '">' . ( LJ::ehtml( $page->description ) || $subject || $page->url ) . "</a>\n\n";
        }
    }

    return {
        subject => $subject,
        event   => $event,
        taglist => $tags,
    };
}


=head2 C<< DW::Controller::Entry::preview_handler( ) >>

Shows a preview of this entry

=cut
sub preview_handler {
    my $r = DW::Request->get;
    my $remote = LJ::get_remote();

    my $post = $r->post_args;
    my $styleid;
    my $siteskinned = 1;

    my $altlogin = $post->{post_as} eq "other" ? 1 : 0;
    my $username = $altlogin ? $post->{username} : $remote->username;
    my $usejournal = $altlogin ? $post->{postas_usejournal} : $post->{usejournal};

    # figure out poster/journal
    my ( $u, $up );
    if ( $usejournal ) {
        $u = LJ::load_user( $usejournal );
        $up = $username ? LJ::load_user( $username ) : $remote;
    } elsif ( $username && $altlogin ) {
        $u = LJ::load_user( $username );
    } else {
        $u = $remote;
    }
    $up ||= $u;

    # set up preview variables
    my ( $ditemid, $anum, $itemid );

    my $form_req = {};
    _decode( $form_req, $post );    # ignore errors

    my ( $event, $subject ) = ( $form_req->{event}, $form_req->{subject} );
    LJ::CleanHTML::clean_subject( \$subject );


    # parse out embed tags from the RTE
    $event = LJ::EmbedModule->transform_rte_post( $event );

    # do first expand_embedded pass with the preview flag to extract
    # embedded content before cleaning and replace with tags
    # the cleaner won't eat
    LJ::EmbedModule->parse_module_embed( $u, \$event, preview => 1 );

    # clean content normally
    LJ::CleanHTML::clean_event( \$event, {
        preformatted => $form_req->{props}->{opt_preformatted},
    } );

    # expand the embedded content for real
    LJ::EmbedModule->expand_entry($u, \$event, preview => 1 );


    my $ctx;
    if ( $u && $up ) {
        $r->note( "_journal"    => $u->{user} );
        $r->note( "journalid"   => $u->{userid} );

        # load necessary props
        $u->preload_props( qw( s2_style ) );


        # determine style system to preview with
        my $forceflag = 0;
        LJ::Hooks::run_hooks( "force_s1", $u, \$forceflag );

        $ctx = LJ::S2::s2_context( $u->{s2_style} );
        my $view_entry_disabled = ! LJ::S2::use_journalstyle_entry_page( $u, $ctx );

        if ( $forceflag || $view_entry_disabled ) {
            # force site-skinned
            ( $siteskinned, $styleid ) = ( 1, 0 );
        } else {
            ( $siteskinned, $styleid ) = ( 0, $u->{s2_style} );
        }
    } else {
        ( $siteskinned, $styleid ) = ( 1, 0 );
    }


    if ( $siteskinned ) {
        my $vars = {
            event   => $event,
            subject => $subject,
            journal => $u,
            poster  => $up,
        };

        my $pic = LJ::Userpic->new_from_keyword( $up, $form_req->{props}->{picture_keyword} );
        $vars->{icon} = $pic ? $pic->imgtag : undef;


        my $etime = LJ::date_to_view_links( $u, "$form_req->{year}-$form_req->{mon}-$form_req->{day}" );
        my $hour = sprintf( "%02d", $form_req->{hour} );
        my $min = sprintf( "%02d", $form_req->{min} );
        $vars->{displaydate} = "$etime $hour:$min:00";


        my %current = LJ::currents( $form_req->{props}, $up );
        if ( $u ) {
            $current{Groups} = $u->security_group_display( $form_req->{allowmask} );
            delete $current{Groups} unless $current{Groups};
        }

        my @taglist = ();
        LJ::Tags::is_valid_tagstring( $form_req->{props}->{taglist}, \@taglist );
        if ( @taglist ) {
            my $base = $u ? $u->journal_base : "";
            $current{Tags} = join( ', ',
                                   map { "<a href='$base/tag/" . LJ::eurl( $_ ) . "'>" . LJ::ehtml( $_ ) . "</a>" }
                                   @taglist
                               );
        }
        $vars->{currents} = LJ::currents_table( %current );

        my $security = "";
        if ( $form_req->{security} eq "private" ) {
            $security = BML::fill_template( "securityprivate" );
        } elsif ( $form_req->{security} eq "usemask" ) {
            $security = BML::fill_template( "securityprotected" );
        }
        $vars->{security} = $security;

        return DW::Template->render_template( 'entry-preview.tt', $vars );
    } else {
        my $ret = "";
        my $opts = {};

        $LJ::S2::ret_ref = \$ret;
        $opts->{r} = $r;

        $u->{_s2styleid} = ( $styleid || 0 ) + 0;
        $u->{_journalbase} = $u->journal_base;

        $LJ::S2::CURR_CTX = $ctx;

        my $p = LJ::S2::Page( $u, $opts );
        $p->{_type} = "EntryPreviewPage";
        $p->{view} = "entry";


        # Mock up entry from form data
        my $userlite_journal = LJ::S2::UserLite( $u );
        my $userlite_poster  = LJ::S2::UserLite( $up );

        my $userpic = LJ::S2::Image_userpic( $up, 0, $form_req->{props}->{picture_keyword} );
        my $comments = LJ::S2::CommentInfo({
            read_url => "#",
            post_url => "#",
            permalink_url => "#",
            count => "0",
            maxcomments => 0,
            enabled => ( $u->{opt_showtalklinks} eq "Y"
                            && ! $form_req->{props}->{opt_nocomments} ) ? 1 : 0,
            screened => 0,
            });

        # build tag objects, faking kwid as '-1'
        # * invalid tags will be stripped by is_valid_tagstring()
        my @taglist = ();
        LJ::Tags::is_valid_tagstring( $form_req->{props}->{taglist}, \@taglist );
        @taglist = map { LJ::S2::Tag( $u, -1, $_ ) } @taglist;

        # custom friends groups
        my $group_names = $u ? $u->security_group_display( $form_req->{allowmask} ) : undef;

        # format it
        my $raw_subj = $form_req->{subject};
        my $s2entry = LJ::S2::Entry($u, {
            subject     => $subject,
            text        => $event,
            dateparts   => "$form_req->{year} $form_req->{mon} $form_req->{day} $form_req->{hour} $form_req->{min} 00 ",
            security    => $form_req->{security},
            allowmask   => $form_req->{allowmask},
            props       => $form_req->{props},
            itemid      => -1,
            comments    => $comments,
            journal     => $userlite_journal,
            poster      => $userlite_poster,
            new_day     => 0,
            end_day     => 0,
            tags        => \@taglist,
            userpic     => $userpic,
            permalink_url       => "#",
            adult_content_level => $form_req->{props}->{adult_content},
            group_names         => $group_names,
        });

        my $copts;
        $copts->{out_pages} = $copts->{out_page} = 1;
        $copts->{out_items} = 0;
        $copts->{out_itemfirst} = $copts->{out_itemlast} = undef;

        $p->{comment_pages} = LJ::S2::ItemRange({
            all_subitems_displayed  => ( $copts->{out_pages} == 1 ),
            current                 => $copts->{out_page},
            from_subitem            => $copts->{out_itemfirst},
            num_subitems_displayed  => 0,
            to_subitem              => $copts->{out_itemlast},
            total                   => $copts->{out_pages},
            total_subitems          => $copts->{out_items},
            _url_of                 => sub { return "#"; },
        });

        $p->{entry} = $s2entry;
        $p->{comments} = [];
        $p->{preview_warn_text} = LJ::Lang::ml( '/entry-preview.tt.entry.preview_warn_text' );

        $p->{viewing_thread} = 0;
        $p->{multiform_on} = 0;


        # page display settings
        if ( $u->should_block_robots ) {
            $p->{head_content} .= LJ::robot_meta_tags();
        }
        $p->{head_content} .= '<meta http-equiv="Content-Type" content="text/html; charset=' . $opts->{'saycharset'} . "\" />\n";
        # Don't show the navigation strip or invisible content
        $p->{head_content} .= qq{
            <style type="text/css">
            html body {
                padding-top: 0 !important;
            }
            #lj_controlstrip {
                display: none !important;
            }
            .invisible {
                position: absolute;
                left: -10000px;
                top: auto;
            }
            .highlight-box {
                border: 1px solid #c1272c;
                background-color: #ffd8d8;
                color: #000;
            }
            </style>
        };


        LJ::S2::s2_run( $r, $ctx, $opts, "EntryPage::print()", $p );
        $r->print( $ret );
        return $r->OK;
    }
}


=head2 C<< DW::Controller::Entry::options_handler( ) >>

Show the entry options page in a separate page

=cut
sub options_handler {
    my ( $ok, $rv ) = controller();
    return $rv unless $ok;

    return DW::Template->render_template( 'entry/options.tt', _options( $rv->{remote} ) );
}


=head2 C<< DW::Controller::Entry::options_rpc_handler( ) >>

Show the entry options page in a form suitable for loading via JS

=cut
sub options_rpc_handler {
    my ( $ok, $rv ) = controller();
    return $rv unless $ok;

    my $vars = _options( $rv->{remote} );
    $vars->{use_js} = 1;
    my $r = DW::Request->get;
    $r->status( @{$vars->{error_list} || []} ? HTTP_BAD_REQUEST : HTTP_OK );

    return DW::Template->render_template( 'entry/options.tt', $vars, { no_sitescheme => 1 } );
}

sub _load_visible_panels {
    my $u = $_[0];

    my $user_panels = $u->entryform_panels;

    my @panels;
    foreach my $panel_group ( @{$user_panels->{order}} ) {
        foreach my $panel ( @$panel_group ) {
            push @panels, $panel if $user_panels->{show}->{$panel};
        }
    }

    return \@panels;
}

sub _options {
    my $u = $_[0];

    my $panel_element_name = "visible_panels";
    my @panel_options;
    foreach ( qw( access comments age_restriction journal crosspost
                    icons tags currents displaydate ) ) {
        push @panel_options, {
            label_ml    => "/entry/$_.tt.header",
            panel_name  => $_,
            id          => "panel_$_",
            name        =>  $panel_element_name,
        }
    }

    my $vars = {
        panels => \@panel_options
    };

    my $r = DW::Request->get;
    if ( $r->did_post ) {
        my $post = $r->post_args;
        $vars->{formdata} = $post;

        if ( LJ::check_form_auth( $post->{lj_form_auth} ) ) {
            if ( $post->{reset_panels} ) {
                $vars->{formdata}->remove( "reset_panels" );
                $u->set_prop( "entryform_panels" => undef );
                $vars->{formdata}->set( $panel_element_name => @{_load_visible_panels( $u )||[]} );
            } else {
                $u->set_prop( entryform_width => $post->{entry_field_width} );

                my %panels;
                my %post_panels = map { $_ => 1 } $post->get_all( $panel_element_name );
                foreach my $panel ( @panel_options ) {
                    my $name = $panel->{panel_name};
                    $panels{$name} = $post_panels{$name} ? 1 : 0;
                }
                $u->entryform_panels_visibility( \%panels );


                my @columns;
                my $didpost_order = 0;
                foreach my $column_index ( 0...2 ) {
                    my @col;

                    foreach ( $post->get_all( "column_$column_index" ) ) {
                        my ( $order, $panel ) = m/(\d+):(.+)_component/;
                        $col[$order] = $panel;

                        $didpost_order = 1;
                    }

                    # remove any in-betweens in case we managed to skip a number in the order somehow
                    $columns[$column_index] = [ grep { $_ } @col];
                }
                $u->entryform_panels_order( \@columns ) if $didpost_order;
            }

            $u->set_prop( js_animations_minimal => $post->{minimal_animations} );
        } else {
            $vars->{error_list} = [ LJ::Lang::ml( "error.invalidform") ];
        }

    } else {

        my $default = {
            entry_field_width   => $u->entryform_width,
            minimal_animations  => $u->prop( "js_animations_minimal" ) ? 1 : 0,
        };

        $default->{$panel_element_name} = _load_visible_panels( $u );

        $vars->{formdata} = $default;
    }

    return $vars;
}

1;