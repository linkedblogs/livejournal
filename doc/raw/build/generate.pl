#!/usr/bin/perl

my $CLEAN = shift;

$home = $ENV{'LJHOME'};
require "$home/cgi-bin/ljlib.pl";
$ENV{'SGML_CATALOG_FILES'} = $LJ::CATALOG_FILES || "/usr/share/sgml/docbook/dtd/xml/4.1/docbook.cat";

unless (-e $ENV{'SGML_CATALOG_FILES'}) {
    die "Catalog files don't exist.\n";
}

$output_dir = "$home/htdocs/doc/temp";
$docraw_dir = "$home/doc/raw";
$XSL = "/usr/share/sgml/docbook/stylesheet/xsl/nwalsh/html/chunk.xsl";
unless (-e $XSL) {
    die "chunk.xsl not found.\n";
}


chdir "$docraw_dir/build" or die;

print ("Generating API reference\n");
system("api/api2db.pl > $docraw_dir/ljp.book/api/api.gen.xml");

print ("Generating DB Schema reference\n");
chdir "$docraw_dir/build/db" or die;
system("./dbschema.pl > dbschema.gen.xml");
system("xsltproc -o schema.gen.xml db2ref.xsl dbschema.gen.xml");
system("mv schema.gen.xml $docraw_dir/ljp.book/db/");
system("rm dbschema.gen.xml");

print ("Generating XML-RPC protocol reference\n");
chdir "$docraw_dir/build/protocol" or die;
system("xsltproc", "-o", "$docraw_dir/ljp.book/csp/xml-rpc/protocol.gen.xml",
       "xml-rpc2db.xsl", "xmlrpc.xml");

print ("Converting to HTML\n");
mkdir $output_dir, 0755 unless -d $output_dir;
chdir $output_dir or die "Couldn't chdir to $output_dir\n";
system("xsltproc --nonet --catalogs --stringparam use.id.as.filename 1 ".
       "$XSL $docraw_dir/index.xml");

if ($CLEAN) {
    print "Removing Auto-generated files\n";
    system("find $docraw_dir -name '*.gen.*' -exec rm {} \;");
}
