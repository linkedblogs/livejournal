#!/usr/bin/perl
#
    
require "$ENV{'LJHOME'}/cgi-bin/ljconfig.pl";

BML::register_block("DOMAIN", "S", $LJ::DOMAIN);
BML::register_block("IMGPREFIX", "S", $LJ::IMGPREFIX);
BML::register_block("SSLIMGPREFIX", "S", $LJ::SSLIMGPREFIX);
BML::register_block("STATPREFIX", "S", $LJ::STATPREFIX);
BML::register_block("SSLSTATPREFIX", "S", $LJ::SSLSTATPREFIX);
BML::register_block("SITEROOT", "S", $LJ::SITEROOT);
BML::register_block("SITENAME", "S", $LJ::SITENAME);
BML::register_block("ADMIN_EMAIL", "S", $LJ::ADMIN_EMAIL);
BML::register_block("SUPPORT_EMAIL", "S", $LJ::SUPPORT_EMAIL);
BML::register_block("CHALRESPJS", "", $LJ::COMMON_CODE{'chalresp_js'});
BML::register_block("JSPREFIX", "S", $LJ::JSPREFIX);
BML::register_block("SSLJSPREFIX", "S", $LJ::SSLJSPREFIX);

# dynamic blocks to implement calling our ljuser function to generate HTML
#    <?ljuser banana ljuser?>
#    <?ljcomm banana ljcomm?>
#    <?ljuserf banana ljuserf?>
BML::register_block("LJUSER", "DS", sub { LJ::ljuser($_[0]->{DATA}); });
BML::register_block("LJCOMM", "DS", sub { LJ::ljuser($_[0]->{DATA}); });
BML::register_block("LJUSERF", "DS", sub { LJ::ljuser($_[0]->{DATA}, { full => 1 }); });

# dynamic needlogin block, needs to be dynamic so we can get at the full URLs and
# so we can translate it
BML::register_block("NEEDLOGIN", "", sub {
    my $loginwidget = LJ::Widget::Login->render(get_ret => 0, ret_cur_page => 1);
    return qq {
        <div><b>You must be logged in to view this page</b></div>
        <div style="margin: 5px;">$loginwidget</div>
    };
});

{
    my $dl = "<a href=\"$LJ::SITEROOT/files/%%DATA%%\">HTTP</a>";
    BML::register_block("DL", "DR", $dl);
}

if ($LJ::UNICODE) {
    BML::register_block("METACTYPE", "S", '<meta http-equiv="Content-Type" content="text/html; charset=utf-8">')
} else {
    BML::register_block("METACTYPE", "S", '<meta http-equiv="Content-Type" content="text/html">')
}


1;
