#!/usr/bin/perl
#

use strict;
use lib "$ENV{'LJHOME'}/cgi-bin";
use Apache;

require 'ljconfig.pl';

# setup httpd.conf things for the user:
Apache->httpd_conf("DocumentRoot $LJ::HTDOCS")
    if $LJ::HTDOCS;
Apache->httpd_conf("ServerAdmin $LJ::ADMIN_EMAIL")
    if $LJ::ADMIN_EMAIL;

Apache->httpd_conf(qq{

# This interferes with LJ's /~user URI, depending on the module order
<IfModule mod_userdir.c>
  UserDir disabled
</IfModule>

PerlInitHandler +Apache::LiveJournal
DirectoryIndex index.html index.bml
});

unless ($LJ::SERVER_TOTALLY_DOWN)
{
    Apache->httpd_conf(qq{
# BML support:
PerlSetVar BMLDomain lj-$LJ::DOMAIN
PerlModule Apache::BML
<Perl>
  Apache::BML::load_config("lj-$LJ::DOMAIN", "$LJ::HOME/cgi-bin/bmlp.cfg");
</Perl>
<Files ~ "\\.bml\$">
  SetHandler perl-script
  PerlHandler Apache::BML
</Files>
});
}

1;
