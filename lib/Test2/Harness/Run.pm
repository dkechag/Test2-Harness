package Test2::Harness::Run;
use strict;
use warnings;

our $VERSION = '0.001100';

use Carp qw/croak/;
use Cwd qw/getcwd/;

use List::Util qw/first/;

use Test2::Util qw/IS_WIN32/;

use Test2::Harness::Util::JSON qw/decode_json/;

use File::Spec;

use Test2::Harness::Util::TestFile;

use Test2::Harness::Util::HashBase qw{
    -run_id

    -finite
    -job_count
    -switches
    -libs -lib -blib -tlib
    -preload
    -load    -load_import
    -args
    -input
    -verbose
    -dummy
    -cover
    -event_uuids
    -mem_usage

    -meta
    -harness_run_fields
    -durations
    -maybe_durations

    -default_search
    -projects
    -search
    -unsafe_inc

    -env_vars
    -use_stream
    -use_fork
    -use_timeout
    -show_times

    -exclude_files
    -exclude_patterns
    -no_long
    -only_long

    -plugins

    -cwd

    -ui
};

sub init {
    my $self = shift;

    # Put this here, before loading data, loaded data means a replay without
    # actually running tests, this way we only die if we are starting a new run
    # on windows.
    croak "preload is not supported on windows"
        if IS_WIN32 && $self->{+PRELOAD};

    croak "The 'run_id' attribute is required"
        unless $self->{+RUN_ID};

    $self->{+SEARCH}     ||= ['t'];
    $self->{+PRELOAD}    ||= undef;
    $self->{+SWITCHES}   ||= [];
    $self->{+ARGS}       ||= [];
    $self->{+LIBS}       ||= [];
    $self->{+LIB}        ||= 0;
    $self->{+BLIB}       ||= 0;
    $self->{+JOB_COUNT}  ||= 1;
    $self->{+INPUT}      ||= undef;

    $self->{+UNSAFE_INC} = 1 unless defined $self->{+UNSAFE_INC};
    $self->{+USE_STREAM} = 1 unless defined $self->{+USE_STREAM};
    $self->{+USE_FORK}   = (IS_WIN32 ? 0 : 1) unless defined $self->{+USE_FORK};

    $self->{+CWD} ||= getcwd();

    croak "Preload requires forking"
        if $self->{+PRELOAD} && !$self->{+USE_FORK};

    my $env = $self->{+ENV_VARS} ||= {};
    $env->{PERL_USE_UNSAFE_INC} = $self->{+UNSAFE_INC} unless defined $env->{PERL_USE_UNSAFE_INC};

    $env->{HARNESS_ACTIVE}    = 1;
    $env->{T2_HARNESS_ACTIVE} = 1;

    $env->{HARNESS_VERSION}    = "Test2-Harness-$VERSION";
    $env->{T2_HARNESS_VERSION} = $VERSION;

    $env->{T2_HARNESS_JOBS} = $self->{+JOB_COUNT};
    $env->{HARNESS_JOBS}    = $self->{+JOB_COUNT};

    $env->{T2_HARNESS_RUN_ID} = $self->{+RUN_ID};

    $self->normalize_ui();

    $self->pull_durations();
}

sub normalize_ui {
    my $self = shift;

    my $specs = delete $self->{+UI} or return;

}

sub pull_durations {
    my $self = shift;

    my $primary  = delete $self->{+MAYBE_DURATIONS} || [];
    my $fallback = delete $self->{+DURATIONS};

    for my $path (@$primary) {
        local $@;
        my $durations = eval { $self->_pull_durations($path) } or print "Could not fetch optional durations '$path', ignoring...\n";
        next unless $durations;

        print "Found durations: $path\n";
        return $self->{+DURATIONS} = $durations;
    }

    return $self->{+DURATIONS} = $self->_pull_durations($fallback)
        if $fallback;
}

sub _pull_durations {
    my $self = shift;
    my ($in) = @_;

    if (my $type = ref($in)) {
        return $self->{+DURATIONS} = $in if $type eq 'HASH';
    }
    elsif ($in =~ m{^https?://}) {
        require HTTP::Tiny;
        my $ht = HTTP::Tiny->new();
        my $res = $ht->get($in, {headers => {'Content-Type' => 'application/json'}});

        die "Could not query durations from '$in'\n$res->{status}: $res->{reason}\n$res->{content}"
            unless $res->{success};

        return $self->{+DURATIONS} = decode_json($res->{content});
    }
    elsif(-f $in) {
        require Test2::Harness::Util::File::JSON;
        my $file = Test2::Harness::Util::File::JSON->new(name => $in);
        return $self->{+DURATIONS} = $file->read();
    }

    die "Invalid duration specification: $in";
}

sub all_libs {
    my $self = shift;

    my $libs = $self->{+LIBS} or return;
    return @$libs;
}

sub TO_JSON {
    my $self = shift;

    my $out = { %$self };

    my $plugins = $self->{+PLUGINS} or return $out;

    my $meta = $out->{+META} //= {};
    my $fields = $out->{+HARNESS_RUN_FIELDS} //= [];
    for my $p (@$plugins) {
        $p->inject_run_data(meta => $meta, fields => $fields, run => $self);
    }

    return $out;
}

sub find_files {
    my $self = shift;

    my $search = $self->search;

    if ($self->{+PROJECTS}) {
        my @out;

        for my $root (@$search) {
            opendir(my $dh, $root) or die "Failed to open project dir: $!";
            for my $file (readdir($dh)) {
                next if $file =~ /^\.+/;
                next unless -d "$root/$file";

                my @sub_search = grep { -d $_ } map { "$root/$file/$_" } @{$self->{+DEFAULT_SEARCH}};
                next unless @sub_search;
                my @new = $self->_find_files(\@sub_search);

                for my $task (@new) {
                    push @{$task->queue_args} => (ch_dir => "$root/$file");

                    push @{$task->queue_args} => (libs => [grep { -d $_ } (
                        "$root/$file/lib",
                        "$root/$file/blib",
                    )]);
                }

                push @out => @new;
            }
        }

        return @out;
    }

    return $self->_find_files($search);
}

sub _find_files {
    my $self = shift;
    my ($search) = @_;

    my $plugins = $self->{+PLUGINS} || [];

    my (@files, @dirs);

    for my $item (@$search) {
        my $claimed;
        for my $plugin (@$plugins) {
            my $file = $plugin->claim_file($item) or next;
            push @files => $file;
            $claimed = 1;
            last;
        }
        next if $claimed;

        push @files => Test2::Harness::Util::TestFile->new(file => $item) and next if -f $item;
        push @dirs  => $item and next if -d $item;
        die "'$item' does not appear to be either a file or a directory.\n";
    }

    if (@dirs) {
        require File::Find;
        File::Find::find(
            {
                no_chdir => 1,
                wanted   => sub {
                    no warnings 'once';
                    return unless -f $_ && m/\.t2?$/;
                    push @files => Test2::Harness::Util::TestFile->new(
                        file => $File::Find::name,
                    );
                },
            },
            @dirs
        );
    }

    push @files => $_->find_files($self, $search) for @$plugins;

    if (my $durations = $self->{+DURATIONS}) {
        for my $file (@files) {
            my $rel = File::Spec->abs2rel($file->file);
            my $dur = $durations->{$rel} or next;
            $file->set_duration($dur);
        }
    }

    $_->munge_files(\@files) for @$plugins;

    # With -jN > 1 we want to sort jobs based on their category, otherwise
    # filename sort is better for people.
    if ($self->{+JOB_COUNT} > 1 || !$self->{+FINITE}) {
        @files = sort { $a->rank <=> $b->rank || $a->file cmp $b->file } @files;
    }
    else {
        @files = sort { $a->file cmp $b->file } @files;
    }

    @files = grep { !$self->{+EXCLUDE_FILES}->{$_->file} } @files if keys %{$self->{+EXCLUDE_FILES}};

    #<<< no-tidy
    @files = grep { my $f = $_->file; !first { $f =~ m/$_/ } @{$self->{+EXCLUDE_PATTERNS}} } @files if @{$self->{+EXCLUDE_PATTERNS}};
    #>>>

    @files = grep { $_->check_duration ne 'long' } @files if $self->{+NO_LONG};
    @files = grep { $_->check_duration eq 'long' } @files if $self->{+ONLY_LONG};

    return @files;
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Run - Test Run Configuration

=head1 DESCRIPTION

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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
