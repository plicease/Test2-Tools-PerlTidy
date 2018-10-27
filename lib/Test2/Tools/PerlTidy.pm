package Test2::Tools::PerlTidy;

use strict;
use warnings;
use 5.008001;
use Test2::API qw( context );
use File::Find ();
use Path::Tiny qw( path );
use Perl::Tidy ();
use IO::File;
use Text::Diff qw( diff );
use base qw( Exporter );

our @EXPORT    = qw( run_tests );
our @EXPORT_OK = qw( run_tests is_file_tidy );

# ABSTRACT: Test2 check that all of your Perl files are tidy
# VERSION

=head1 SYNOPSIS

=head1 DESCRIPTION

This module lets you test your code for tidiness.  It is more or less a drop in replacement
for L<Test::PerlTidy>, except that it is implemented using L<Test2::API>, and it handles
UTF-8 (a common encoding for Perl source code) better, and works on windows.

=head1 FUNCTIONS

=head2 run_tests

 run_tests %args;

Test all perl files for tidiness.  Options:

=over 4

=item exclude

C<run_tests> will look for files to test under the current directory recursively.  by default
it will exclude files in the C<./blib/> directory.  Set C<exclude> to a list reference to
exclusion criteria if you need to exclude additional files.  Strings are assumed to be
path prefixes and regular expressions can be used to match any part of the file path name.

Note that unlike L<Test::PerlTidy>, this module does NOT use
L<File::Spec|File::Spec>C<< ->canonpath >> before matching is attempted, because that breaks
this module on windows.  Instead L<Path::Tiny> is used which gives consistent results on both
UNIX and Windows.

=item path

Set C<path> to the path of the top-level directory that contains the files to be
tested.  Defaults to C<.>.

=item perltidyrc

By default the usual locations for the B<perltidyrc> file will be searched.  You can use
this to override a specific tidy file.

=item mute

Off by default, silence diagnostics.

=item skip_all

Set C<skip_all> to a true value to skip the whole test file.  There isn't really a good
reason to use this over the L<Test2::V0> C<skip_all> function.

=item no_plan

Set C<no_plan> to skip the plan.  By default a plan with the number of files to be tested is
performed.  There isn't really a good reason to use this over a C<done_testing> call, but
this is the default to maintain backward compatibility with L<Test::PerlTidy>.

=back

=cut

sub run_tests
{
  my %args = @_;

  my $ctx = context();

  if($args{skip_all})
  {
    $ctx->plan(0, SKIP => 'All tests skipped.');
  }

  my @files = list_files(%args);

  $ctx->plan(scalar @files) unless $args{no_plan};

  foreach my $file (@files)
  {
    my @diag;
    my $name = "'$file'";
    $args{diag} = sub { push @diag, @_ };
    my $ok = is_file_tidy($file, $args{perltidyrc}, %args);
    if($ok)
    {
      $ctx->pass($name);
    }
    else
    {
      $ctx->fail($name, @diag);
    }
  }

  $ctx->release;

  ();
}

=head2 is_file_tidy

 use Test2::Tools::PerlTidy qw( is_file_tidy );
 my $bool = is_file_tidy $filename;
 my $bool = is_file_tidy $filename, $perltidyrc;

Returns true if the file is tidy or false otherwise.  Sends diagnostics via the L<Test2> API.
Exportable on request.

=cut

sub is_file_tidy
{
  my($file_to_tidy, $perltidyrc, %args) = @_;

  my $code_to_tidy = load_file($file_to_tidy);

  my $ctx         = context();
  my $diag        = $args{mute} ? sub { } : $args{diag} || sub { $ctx->diag(shift) };
  my $tidied_code = '';
  my $logfile     = '';
  my $errorfile   = '';

  unless(defined $code_to_tidy)
  {
    $diag->("Unable to find or read '$file_to_tidy'");
    $ctx->release;
    return 0;
  }

  my $stderr_fh = IO::File->new_tmpfile or die "Unable to open temp file $!";
  $stderr_fh->autoflush(1);

  Perl::Tidy::perltidy(
    source      => \$code_to_tidy,
    destination => \$tidied_code,
    stderr      => $stderr_fh,
    logfile     => \$logfile,
    errorfile   => \$errorfile,
    perltidyrc  => $perltidyrc,
  );

  $stderr_fh->seek(0,0);
  my $stderr = do {
    local $/;
    <$stderr_fh>;
  };

  my @diag;

  if($stderr)
  {
    $diag->("perltidy reported the following errors:");
    $diag->($stderr);
    $ctx->release;
    return 0;
  }

  $code_to_tidy =~ s/[\r\n]+$//;
  $tidied_code  =~ s/[\r\n]+$//;

  if($code_to_tidy eq $tidied_code)
  {
    $ctx->release;
    return 1;
  }
  else
  {
    $diag->("The file '$file_to_tidy' is not tidy");
    $diag->(diff( \$code_to_tidy, \$tidied_code, { STYLE => 'Table' }));
    $ctx->release;
    return 0;
  }
}

=head2 list_files

 my @files = Test2::Tools::PerlTidy::list_files $path;
 my @files = Test2::Tools::PerlTidy::list_files %args;

Generate the list of files to be tested.  Don't use this.  Included as part of the public
interface for backward compatibility with L<Test::PerlTidy>.  Not exported.

=cut

sub list_files
{
  my %args;
  my $path;

  # path as only argument is for backward compatability with Test::PerlTidy
  if(@_ > 1)
  {
    %args = @_;
    $path = $args{path};
  }
  else
  {
    ($path) = @_;
  }

  $path ||= '.';

  my $ctx = context();

  $ctx->bail("$path does not exist") unless -e $path;
  $ctx->bail("$path is not a directory") unless -d $path;

  my $excludes = $args{exclude} || [qr/^blib\//];   # exclude blib by default

  $ctx->bail("exclude must be an array")
    unless ref $excludes eq 'ARRAY';

  my @files;

  File::Find::find(
    sub {
      my $filename = $_;
      return if -d $filename;
      my $path = path($File::Find::name);
      foreach my $exclude (@$excludes)
      {
        return if ref $exclude ? $path =~ $exclude : $path =~ /^$exclude/;
      }
      push @files, $path if $filename =~ /\.(?:pl|pm|PL|t)$/;
    },
    $path,
  );

  $ctx->release;

  map { "$_" } sort @files;
}

=head2 load_file

 my $content = Test2::Tools::PerlTidy::load_file $filename;

Load the UTF-8 encoded file to be tested from disk and return the contents.  Don't use this.
Included as part of the public interface for backward compatibility with L<Test::PerlTidy>.
Not exported.

=cut

sub load_file
{
  my($filename) = @_;
  return unless defined $filename && -f $filename;
  path($filename)->slurp_utf8;
}

1;
