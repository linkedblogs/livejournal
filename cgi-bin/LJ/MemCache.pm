#
# Wrapper around MemCachedClient

use lib "$ENV{'LJHOME'}/cgi-bin";
use Cache::Memcached;

package LJ::MemCache;

%LJ::MEMCACHE_ARRAYFMT = (
                          'user' =>
                          [qw[1 userid user caps clusterid dversion email password status statusvis statusvisdate
                              name bdate themeid moodthemeid opt_forcemoodtheme allow_infoshow allow_contactshow
                              allow_getljnews opt_showtalklinks opt_whocanreply opt_gettalkemail opt_htmlemail
                              opt_mangleemail useoverrides defaultpicid has_bio txtmsg_status is_system
                              journaltype lang oldenc]],
                          'fgrp' => [qw[1 userid groupnum groupname sortorder is_public]],
                          );


my $memc;  # memcache object

sub init {
    $memc = new Cache::Memcached;
    trigger_bucket_reconstruct();
}

sub client_stats {
    return $memc->{'stats'} || {};
}

sub trigger_bucket_reconstruct {
    $memc->set_servers(\@LJ::MEMCACHE_SERVERS);
    $memc->set_debug($LJ::MEMCACHE_DEBUG);
    $memc->set_compress_threshold($LJ::MEMCACHE_COMPRESS_THRESHOLD);
    $memc->set_readonly(1) if $ENV{LJ_MEMC_READONLY};
    return $memc;
}

sub forget_dead_hosts { $memc->forget_dead_hosts(); }
sub disconnect_all    { $memc->disconnect_all();    }

sub delete {
    # use delete time if specified
    return $memc->delete(@_) if defined $_[1];

    # else default to 4 seconds:
    # version 1.1.7 vs. 1.1.6
    $memc->delete(@_, 4) || $memc->delete(@_);
}

sub add       { $memc->add(@_);       }
sub replace   { $memc->replace(@_);   }
sub set       { $memc->set(@_);       }
sub get       { $memc->get(@_);       }
sub get_multi { $memc->get_multi(@_); }
sub incr      { $memc->incr(@_);      }
sub decr      { $memc->decr(@_);      }

sub _get_sock { $memc->get_sock(@_);   }

sub run_command { $memc->run_command(@_); }


sub array_to_hash {
    my ($fmtname, $ar) = @_;
    my $fmt = $LJ::MEMCACHE_ARRAYFMT{$fmtname};
    return undef unless $fmt;
    return undef unless $ar && ref $ar eq "ARRAY" && $ar->[0] == $fmt->[0];
    my $hash = {};
    my $ct = scalar(@$fmt);
    for (my $i=1; $i<$ct; $i++) {
        $hash->{$fmt->[$i]} = $ar->[$i];
    }
    return $hash;
}

sub hash_to_array {
    my ($fmtname, $hash) = @_;
    my $fmt = $LJ::MEMCACHE_ARRAYFMT{$fmtname};
    return undef unless $fmt;
    return undef unless $hash && ref $hash eq "HASH";
    my $ar = [$fmt->[0]];
    my $ct = scalar(@$fmt);
    for (my $i=1; $i<$ct; $i++) {
        $ar->[$i] = $hash->{$fmt->[$i]};
    }
    return $ar;
}

1;
