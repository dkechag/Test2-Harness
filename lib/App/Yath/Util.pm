package App::Yath::Util;
use strict;
use warnings;

our $VERSION = '0.999006';

use File::Spec;

use Test2::Harness::Util qw/clean_path/;

use Cwd qw/realpath/;
use Importer Importer => 'import';
use Config qw/%Config/;
use Carp qw/croak/;

our @EXPORT_OK = qw{
    find_pfile
    find_in_updir
    is_generated_test_pl
    fit_to_width
    isolate_stdout
    find_yath
};

sub find_yath {
    return $App::Yath::Script::SCRIPT if defined $App::Yath::Script::SCRIPT;

    if (-d 'scripts') {
        my $script = File::Spec->catfile('scripts', 'yath');
        return $App::Yath::Script::SCRIPT = clean_path($script) if -e $script && -x $script;
    }

    my @keys = qw{
        bin binexp initialinstalllocation installbin installscript
        installsitebin installsitescript installusrbinperl installvendorbin
        scriptdir scriptdirexp sitebin sitebinexp sitescript sitescriptexp
        vendorbin vendorbinexp
    };

    my %seen;
    for my $path (@Config{@keys}) {
        next unless $path;
        next if $seen{$path}++;

        my $script = File::Spec->catfile($path, 'yath');
        next unless -f $script && -x $script;

        $App::Yath::Script::SCRIPT = $script = clean_path($script);
        return $script;
    }

    die "Could not find yath in Config paths";
}

sub isolate_stdout {
    # Make $fh point at STDOUT, it is our primary output
    open(my $fh, '>&', STDOUT) or die "Could not clone STDOUT: $!";
    select $fh;
    $| = 1;

    # re-open STDOUT redirected to STDERR
    open(STDOUT, '>&', STDERR) or die "Could not redirect STDOUT to STDERR: $!";
    select STDOUT;
    $| = 1;

    # Yes, we want to keep STDERR selected
    select STDERR;
    $| = 1;

    return $fh;
}

sub is_generated_test_pl {
    my ($file) = @_;

    open(my $fh, '<', $file) or die "Could not open '$file': $!";

    my $count = 0;
    while (my $line = <$fh>) {
        last if $count++ > 5;
        next unless $line =~ m/^# THIS IS A GENERATED YATH RUNNER TEST$/;
        return 1;
    }

    return 0;
}


sub find_in_updir {
    my $path = shift;
    return clean_path($path) if -f $path;

    my %seen;
    while(1) {
        $path = File::Spec->catdir('..', $path);
        my $check = eval { realpath(File::Spec->rel2abs($path)) };
        last unless $check;
        last if $seen{$check}++;
        return $check if -f $check;
    }

    return;
}

sub find_pfile {
    my ($settings, %params) = @_;

    croak "Settings is a required argument" unless $settings;

    # First do the entire search without vivify
    if ($params{vivify}) {
        my $found = find_pfile($settings, %params, vivify => 0);
        return $found if $found;
    }

    my $yath = $settings->harness;

    if (my $pfile = $yath->persist_file) {
        return $pfile if -f $pfile || $params{vivify};

        return; # Specified, but not found and no vivify
    }

    my $project = $yath->project;
    my $name = $project ? "$project-yath-persist.json" : "yath-persist.json";
    my $set_dir = $yath->persist_dir // $ENV{YATH_PERSISTENCE_DIR};
    my $dir = $set_dir // $ENV{TMPDIR} // $ENV{TEMPDIR} // File::Spec->tmpdir;

    # If a dir was specified, or if the current dir is not writable then we must use $dir/$name
    if ($project || $set_dir || !-w '.') {
        my $pfile = clean_path(File::Spec->catfile($dir, $name));
        return $pfile if -f $pfile || $params{vivify};

        return; # Not found, no vivify
    }

    # Fall back to using the current dir (which must be writable)
    $name = ".yath-persist.json";
    my $pfile = find_in_updir($name);
    return $pfile if $pfile && -f $pfile;

    # Creating it here!
    return $name if $params{vivify};

    # Nope, nothing.
    return;
}

sub fit_to_width {
    my ($width, $join, $text) = @_;

    my @parts = ref($text) ? @$text : split /\s+/, $text;

    my @out;

    my $line = "";
    for my $part (@parts) {
        my $new = $line ? "$line$join$part" : $part;

        if ($line && length($new) > $width) {
            push @out => $line;
            $line = $part;
        }
        else {
            $line = $new;
        }
    }
    push @out => $line if $line;

    return join "\n" => @out;
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Util - General utilities for yath that do not fit anywhere else.

=head1 DESCRIPTION

This package exports several tools used throughout yath that did not fit into
any other package.

=head1 SYNOPSIS

    use App::Yath::Util qw{
        find_pfile
        find_in_updir
        is_generated_test_pl
        fit_to_width
        isolate_stdout
        find_yath
    };

=head1 EXPORTS

Note that nothing is exported by default, you must request each function to
import.

=over 4

=item $path_to_pfile = find_pfile($settings, %params)

The first argument must be an instance of L<Test2::Harness::Settings>.

Currently the only supported param is C<vivify>, when set to true the pfile
will be created if one does not already exist.

The pfile is a file that tells yath that a persistent runner is active, and how
to communicate with it.

=item $path_to_file = find_in_updir($file_name)

Look for C<$file_name> in the current directory or any parent directory.

=item $bool = is_generated_test_pl($path_to_test_file)

Check if the specified test file was generated by the C<yath init> command.

=item fit_to_width($width, $join, $text)

This will split the C<$text> on space, and then recombine it using C<$join>
inserting newlines as necessary in an attempt to fit the text into C<$width>
horizontal characters. If any words are larger than C<$width> they will not be
split and text-wrapping may occur if used for terminal display.

=item $stdout = isolate_stdout()

This will close STDOUT and reopen it to point at STDERR. The result of this is
that any print statement that does not specify a fielhandle will print to
STDERR instead of STDOUT, in addition any print directly to STDOUT will instead
go to STDERR. A filehandle to the real STDOUT is returned for you to use when
you actually want to write to STDOUT.

This is used by some yath processes that need to print structured data to
STDOUT without letting any third part modules they may load write to the real
STDOUT.

=item $path_to_script = find_yath()

This will attempt to find the C<yath> command line script. When possible this
will return the path that was used to launch yath. If yath was not run to start
the process it will search the paths specified in the L<Config> module. This
will throw an exception if the script cannot be found.

Note: The result is cached so that subsequent calls will return the same path
even if something installs a new yath script in another location that would
otherwise be found first. This guarentees that a single process will not switch
scripts.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
