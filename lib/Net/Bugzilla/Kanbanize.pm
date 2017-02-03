use strict;
use warnings;

package Net::Bugzilla::Kanbanize;

our $VERSION;

#ABSTRACT: Bugzilla and Kanbanize sync tool

use Data::Dumper;

use Net::Bugzilla::Kanbanize;

use LWP::Simple;
use JSON;

use LWP::UserAgent;
use File::HomeDir;

use HTTP::Request;
use URI::Escape;
use List::MoreUtils qw(uniq);

use Log::Log4perl ();

#XXX: https://bugzil.la/970457

my $log = Log::Log4perl::get_logger();

sub new {
    my ( $class, $config ) = @_;

    my $self = bless { config => $config }, $class;

    return $self;
}

=head2 version

prints current version to STDERR

=cut

sub version {
    return $VERSION || "git";
}

#XXX: Wrong, need to be instance variables

my $all_cards;
my %bugs;

my $APIKEY;
my $BOARD_ID;
my $BUGZILLA_TOKEN;
my $KANBANIZE_INCOMING;
my $KANBANIZE_PRIORITY;
my $WHITEBOARD_TAG;
my @COMPONENTS;
my @PRODUCTS;
my %BUGMAIL_TO_KANBANID;
my %KANBANID_TO_BUGMAIL;

my $DRYRUN;
my $ua = LWP::UserAgent->new();

my $total;
my $count;
my $config;

sub run {
    my $self = shift;

    $config = $self->{config};

    $DRYRUN = $config->get('test');

    $APIKEY = ( $config->kanbanize_apikey || $ENV{KANBANIZE_APIKEY}) or die "Please configure an apikey";
    $BOARD_ID = ( $config->kanbanize_boardid || $ENV{KANBANIZE_BOARDID})
      or die "Please configure a kanbanize_boardid";
    $BUGZILLA_TOKEN = ( $config->bugzilla_token || $ENV{BUGZILLA_TOKEN})
      or die "Please configure a bugzilla_token";

    $KANBANIZE_INCOMING = $config->kanbanize_incoming;
    $KANBANIZE_PRIORITY = $config->kanbanize_priority || "Average";

    $WHITEBOARD_TAG = $config->tag || die "Missing whiteboard tag";

    @COMPONENTS = @{$config->component};
    @PRODUCTS = @{$config->product};

    %BUGMAIL_TO_KANBANID = %{$config->get("mail-map_bugmail")};
    %KANBANID_TO_BUGMAIL = reverse %BUGMAIL_TO_KANBANID;

    $ua->timeout(15);
    $ua->env_proxy;
    $ua->default_header( 'apikey' => $APIKEY );

    if (@ARGV) {
        # fill_missing_bugs_info() needs to know the sourceid of each bugid.
        # This isn't really necessary for @ARGV, but we conform anyways.
        my %sourcemap = ();
        for (0..$#ARGV) {
            $sourcemap{$_} = $ARGV[$_];
        }

        # Go fetch all these bugs and ensure we process them.
        fill_missing_bugs_info( "argv", \%bugs, \%sourcemap );
    }
    else {
        %bugs = get_bugs();
    }

    $count = scalar keys %bugs;

    $log->debug("Found a total of $count bugs");

    find_mislinked_bugs( \%bugs );
    find_mislinked_cards();

    $total = 0;

    while ( my ( $bugid, $bug ) = each %bugs ) {
        sync_bug($bug);
    }

    return 1;
}

sub find_mislinked_bugs {
    my($bugs) = @_;

    # whiteboard link -> [ bug, bug, ... ]
    my %whiteboards = ();

    while ( my( $bugid, $bug ) = each %{ $bugs } ) {
        # convert the bug into a card, if it exists.
        my $card = parse_whiteboard($bug->{whiteboard});
        if (defined $card) {
            # we only need the cardid for this check.
            my $cardid = $card->{taskid};
            if ($cardid) {
                # set it up to be an array, if it isn't one already.
                $whiteboards{$cardid} ||= [];
                # append the bug we found to the array.
                push(@{ $whiteboards{$cardid} }, $bugid);
            }
        }
    }

    while ( my( $cardid, $bugids ) = each %whiteboards ) {
        if (@{ $bugids } > 1) {
            $log->warn("Card $cardid is referenced by whiteboards on multiple bugs: " . join(', ', @{ $bugids }));

            # Plan to create a new card for each of these bugs.
            my %multiple_bugs = map { $_ => 1 } @{ $bugids };

            # However, if the card references one of these bugs, leave that one bug alone.
            my $extlink = $all_cards->{$cardid}->{extlink};
            if (defined($extlink)) {
                # The card has an extlink. Check of the bugs.
                for my $bugid (sort keys %multiple_bugs) {
                    # Does this bugid match the card?
                    if ($extlink =~ /show_bug.cgi.*id=$bugid$/) {
                        # It does! Delete it from the list of bugs to get new cards.
                        $log->warn("Card $cardid is already correctly associated with bug $bugid");
                        delete $multiple_bugs{$bugid};
                        last;
                    }
                }
            }

            # Assign a new card to each of the bugs left after the above logic is done.
            for my $bugid (uniq sort keys %multiple_bugs) {
                my $bug = $bugs->{$bugid};

                my $found_cardid = find_card_for_bugid($bugid);
                if ($found_cardid) {
                    my $found_card = retrieve_card($found_cardid);

                    if ( not $found_card ) {
                        $log->warn("Failed to load existing card for bug $bug->{id} card $found_cardid");
                        return;
                    }

                    $bug->{whiteboard} = update_whiteboard( $bug->{id}, $found_card->{taskid}, $bug->{whiteboard} );

                    my $change = "[assigned existing card $found_card->{taskid} to bug $bug->{id} replacing conflicted card $cardid]";
                    $log->info(sprintf "Card %4d - Bug %8d - [%s] %s ** %s **",
                      $found_card->{taskid}, $bug->{id}, $bug->{source}, $bug->{summary}, $change);
                } else {
                    my $new_card = create_card($bug);

                    if ( not $new_card ) {
                        $log->warn("Failed to create new card for bug $bug->{id}");
                        return;
                    }

                    $bug->{whiteboard} = update_whiteboard( $bug->{id}, $new_card->{taskid}, $bug->{whiteboard} );

                    my $change = "[assigned new card $new_card->{taskid} to bug $bug->{id} replacing conflicted card $cardid]";
                    $log->info(sprintf "Card %4d - Bug %8d - [%s] %s ** %s **",
                      $new_card->{taskid}, $bug->{id}, $bug->{source}, $bug->{summary}, $change);
                }
            }
        }
    }
}

sub is_archived_card {
    my($card, $check_history) = @_;

    if ($card->{columnname} eq 'Archive') {
        # This is a temporarily-archived card.
        return 1;
    } elsif (defined($check_history) && $check_history) {
        # Loading the card history takes an extra API call.
        load_card_history($card);
        if (eval { no warnings 'uninitialized'; $card->{historydetails}[0]{historyevent} eq 'Task archived' }) {
            # This is a permanently-archived card.
            return 1;
        }
    }
    # This is NOT an archived card, to the best of our knowledge.
    return 0;
}

sub find_card_for_bugid {
    my($bugid, $skip_archived) = @_;

    my $bug = $bugs{$bugid};

    # If we find an archived card, store it in case we can't find any other card.
    my $found_archived;

    for my $cardid (sort { $a <=> $b } keys %{ $all_cards }) {
        my $card = $all_cards->{$cardid};
        my $extlink = $card->{extlink};
        if (defined($extlink) && $extlink =~ /show_bug.cgi.*id=$bugid$/) {
            # See if the card is archived, loading the history if necessary.
            if (is_archived_card($card, 1)) {
                # Record the oldest archived card we find, but keep searching.
                $found_archived ||= $card;
            } else {
                # We found a non-archived card. Return it, since that's great.
                return $cardid;
            }
        }
    }

    # If we reached this point, either we found no cards or an archived card.
    if ($skip_archived) {
        # We aren't supposed to return any archived cards we found, so return undef.
        return undef;
    } else {
        # We return either the first archived card we found, or undef if none found.
        return $found_archived;
    }
}

sub find_mislinked_cards {
    # whiteboard link -> [ bug, bug, ... ]
    my %extlinks = ();

    while ( my( $cardid, $card ) = each %{ $all_cards } ) {
        next if $card->{columnname} eq 'Archive';
        my $extlink = $card->{extlink};
        if (defined($extlink) && $extlink =~ /show_bug.cgi.*id=(\d+)$/) {
            $extlinks{$1} ||= [];
            push(@{ $extlinks{$1} }, $cardid);
        }
    }

    while ( my( $bugid, $cardids ) = each %extlinks ) {
        if (@{ $cardids } > 1) {
            $log->warn("Bug $bugid is referenced by extlinks on multiple cards: " . join(', ', @{ $cardids }));
        }
    }
}

use URI;
use URI::QueryParam;

sub get_bug_history {
    my($bug) = @_;

    die "Invalid bug number" unless $bug =~ /^\d+$/;

    my $uri = URI->new("https://bugzilla.mozilla.org/rest/bug/$bug/history");
    $uri->query_param(token => $BUGZILLA_TOKEN);

    my $req = HTTP::Request->new( GET => $uri );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }

    my $data = decode_json( $res->decoded_content );

    my $results = [];

    # If this fails, we didn't get a bug history for whatever reason. Oh well.
    eval {
        for my $h (@{ $data->{'bugs'} }) {
            next unless $h->{'id'} eq $bug;
            if (@{ $h->{'history'} } > 0) {
                $results = $h->{'history'};
            }
        }
    };
    # XXX: Lazily assuming that no data and bad data are equivalent and okay here.
    #warn "$@" if $@;

    return $results;
}

sub get_bug_history_latest {
    my($bug, $field) = @_;

    die "Invalid bug number" unless $bug =~ /^\d+$/;
    die "Invalid field name" unless $field =~ /^\S+$/;

    my $history = get_bug_history($bug);

    my @timestamps = ();

    for my $entry (@{ $history }) {
        my $changes = $entry->{'changes'};
        my $found = 0;
        for my $change (@{$changes}) {
            next unless $change->{'field_name'} eq $field;
            $found = 1;
            last;
        }
        next unless $found;
        push @timestamps, $entry->{'when'};
    }

    # stop if we didn't find any history entries
    return '' unless @timestamps > 0;

    # sorts times of the format "2015-04-17T20:45:07Z" oldest to newest.
    @timestamps = sort @timestamps;

    # return the newest timestamp.
    return $timestamps[-1];
}

sub refresh_card {
    my($card) = @_;

    # We'll need the cardid to refresh this.
    my($cardid) = $card->{taskid};

    # Remove this card from the cache.
    delete ${ $all_cards }{$cardid};

    # Re-fetch the card.
    return retrieve_card($cardid, 0);
}

sub load_card_history {
    my($card) = @_;

    # Ensure that we've fetched the history for this card, if it isn't already cached.
    unless (exists $card->{'historydetails'}) {
        # The cache is populated by get_all_tasks, which doesn't have access to history data.
        # So we need to clear the cache and re-fetch the card, to get its history.
        $card = refresh_card($card);
    }

    return $card;
}

sub get_card_history_latest {
    my($card, $field, $details) = @_;

    $card = load_card_history($card);

    my $cardid = $card->{'taskid'};

    my $history = $card->{'historydetails'};

    my @timestamps = ();

    for my $change (@{ $history }) {
        next unless exists $change->{'historyevent'};
        next unless $change->{'historyevent'} =~ /$field/i;
        if (defined($details)) {
            next unless $change->{'details'} =~ /$details/;
        }
        my $entrydate = $change->{'entrydate'};
        $entrydate =~ s/^(....-..-..) (..:..:..)$/$1T$2Z/;
        die "Unable to post-process entrydate from kanbanize" unless $entrydate =~ /^....-..-..T..:..:..Z$/;
        push @timestamps, $entrydate;
    }

    # stop if we didn't find any history entries
    return '' unless @timestamps > 0;

    # sorts times of the format "2015-04-17T20:45:07Z" oldest to newest.
    @timestamps = sort @timestamps;

    # return the newest timestamp.
    return $timestamps[-1];
}

sub get_bugs {
    my $uri = URI->new("https://bugzilla.mozilla.org/rest/bug");

    $uri->query_param(token => $BUGZILLA_TOKEN);
    $uri->query_param(include_fields => qw(id status whiteboard summary assigned_to creation_time));
    $uri->query_param(bug_status => qw(NEW UNCONFIRMED REOPENED ASSIGNED));
    $uri->query_param(product => @PRODUCTS);
    $uri->query_param(component => @COMPONENTS);

    my $req = HTTP::Request->new( GET => $uri );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }

    my $data = decode_json( $res->decoded_content );

    my %bugs;

    foreach my $bug ( @{ $data->{bugs} } ) {
        $bugs{ $bug->{id} } = $bug;
        $bugs{ $bug->{id} }{source} = "search";
        $bugs{ $bug->{id} }{sourceids} = [];
    }

    my @marked = get_marked_bugs();

    foreach my $bug (@marked) {
        $bugs{ $bug->{id} } = $bug;
        $bugs{ $bug->{id} }{source} = "marked";
        $bugs{ $bug->{id} }{sourceids} = [];
    }

    my @cced = get_cced_bugs();

    foreach my $bug (@cced) {
        $bugs{ $bug->{id} } = $bug;
        $bugs{ $bug->{id} }{source} = "cc";
        $bugs{ $bug->{id} }{sourceids} = [];
    }

    my $cards = get_bugs_from_all_cards();

    fill_missing_bugs_info( "card", \%bugs, $cards );

    return %bugs;
}

sub fill_missing_bugs_info {
    my ( $source, $bugs, $sourcemap ) = @_;

    my %bug_to_source;

    for my $sourceid (sort keys %{ $sourcemap }) {
        my $bugid = $sourcemap->{$sourceid};
        if (exists $bugs->{$bugid}) {
            delete $sourcemap->{$sourceid};
        } else {
            $bug_to_source{$bugid} ||= [];
            push(@{ $bug_to_source{$bugid} }, $sourceid);
        }
    }

    unless (keys %{ $sourcemap } > 0) {
        return;
    }

    my $missing_bugs_ids = join(",", uniq sort values %{ $sourcemap });

    my $url = "https://bugzilla.mozilla.org/rest/bug?token=$BUGZILLA_TOKEN&include_fields=id,status,whiteboard,summary,assigned_to&id=$missing_bugs_ids";

    my $req =
      HTTP::Request->new( GET => $url );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }

    my $data = decode_json( $res->decoded_content );

    my @found_bugs = @{ $data->{bugs} };

    foreach my $bug ( sort @found_bugs ) {
        $bugs->{ $bug->{id} } = $bug;
        $bugs->{ $bug->{id} }{source} = $source;
        $bugs->{ $bug->{id} }{sourceids} = $bug_to_source{ $bug->{id} };
    }

    return;
}

# Also retrieve bugs we are cc'ed on.
sub get_cced_bugs {
    my $email = $config->bugzilla_id || $ENV{BUGZILLA_ID};

    my $req =
      HTTP::Request->new( GET =>
"https://bugzilla.mozilla.org/rest/bug?token=$BUGZILLA_TOKEN&include_fields=id,status,whiteboard,summary,assigned_to&bug_status=UNCONFIRMED&bug_status=NEW&bug_status=ASSIGNED&bug_status=REOPENED&emailcc1=1&emailtype1=exact&email1=$email"
      );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }

    my $data = decode_json( $res->decoded_content );

    my @bugs = @{ $data->{bugs} };

    return @bugs;
}

sub get_marked_bugs {
    my $uri = URI->new("https://bugzilla.mozilla.org/rest/bug");

    $uri->query_param(token => $BUGZILLA_TOKEN);
    $uri->query_param(include_fields => qw(id status whiteboard summary assigned_to));
    $uri->query_param(bug_status => qw(NEW UNCONFIRMED REOPENED ASSIGNED));
    $uri->query_param(product => @PRODUCTS);
    $uri->query_param(status_whiteboard_type => 'allwordssubstr');
    $uri->query_param(query_format => 'advanced');
    $uri->query_param(status_whiteboard => "[kanban:$WHITEBOARD_TAG]");

    my $req =
      HTTP::Request->new( GET => $uri );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }

    my $data = decode_json( $res->decoded_content );

    my @bugs = @{ $data->{bugs} };

    return @bugs;
}

sub get_bugs_from_all_cards {

    my $req =
      HTTP::Request->new( POST =>
"https://$WHITEBOARD_TAG.kanbanize.com/index.php/api/kanbanize/get_all_tasks/boardid/$BOARD_ID/format/json"
      );

    $req->header( "Content-Length" => "0" );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }

    my $cards = decode_json( $res->decoded_content );

    my %found_cards;
    foreach my $card (@$cards) {
        $all_cards->{ $card->{taskid} } = $card;

        my $extlink = $card->{extlink};    # XXX: Smarter parsing
        if ( $extlink =~ /(\d+)$/ ) {
            my $bugid = $1;
            $found_cards{ $card->{taskid} } = $bugid;
        }
    }

    return \%found_cards;
}

sub sync_bug {
    my $bug = shift;

    #    print STDERR "Bugid: $bug->{id}\n" if $config->verbose;

    $total++;

    if ( not defined $bug ) {
        $log->warn("[$total/$count] No info for bug $bug->{id}");
        return;
    }

    if ( $bug->{error} ) {
        $log->warn("[$total/$count] No info for bug $bug->{id} (Private bug?)");
        return;
    }

    my $summary    = $bug->{summary};
    my $whiteboard = $bug->{whiteboard};

    my $card = parse_whiteboard($whiteboard);

    my @changes;
    if ( not defined $card ) {

        # For the source to be 'card' here, the bug has to have traversed a series of logic
        # steps to reach this point:
        #
        # - a card must have an extlink to the bug
        # - the bug must not be returned by the watched components search
        # - the bug must not have a cc: of the kanban watch user.
        #
        if (defined($whiteboard) && length($whiteboard) > 0) {
            $log->debug("Bug $bug->{id} whiteboard << $whiteboard >> did not resolve to a card.") if $config->verbose;
        }

        if ($bug->{source} eq 'card') {
            # If all three of these conditions are true, then we assume the bug is not meant
            # to be watched in Kanban, and complete all open cards that reference it.
            my $found_unclosed_cards = 0;
            for my $cardid (@{ $bug->{sourceids} }) {
                my $card = retrieve_card($cardid, $bug->{id});
                if ($card->{columnname} ne 'Done' && $card->{columnname} ne 'Archive') {
                    $found_unclosed_cards++;
                    if ($found_unclosed_cards == 1) {
                        $log->warn("Bug $bug->{id} came from an open card, but whiteboard is empty; closing the associated card(s).");
                    }
                    complete_card($card);
                    my $change = "[closed card $cardid for departed bug $bug->{id}]";
                    $log->info(sprintf "[%4d/%4d] Card %4d - Bug %8d - [%s] %s ** %s **",
                      $total, $count, $cardid, $bug->{id}, $bug->{source}, $summary, $change);
                }
            }
            return;
        }
        # Otherwise, the source is either 'argv' or 'cc' or 'search'. Onward to whiteboard.

        my $found_cardid = find_card_for_bugid($bug->{id});
        if ( defined $found_cardid ) {
            # We found a usable (non-archived) card referencing this bug, so reuse it.
            $card = retrieve_card($found_cardid, $bug->{id});

            $log->warn("Bug $bug->{id} already has a card $found_cardid, updating whiteboard");

            update_whiteboard($bug->{id}, $found_cardid, $whiteboard);

            push @changes, "[bug updated]";
        } else {
            # We did not find a usable (non-archived) card referencing this bug, so open a new one.
            $log->warn("Bug $bug->{id} whiteboard << $whiteboard >> references an unknown (or archived) card, creating a new card");

            $card = create_card($bug);

            if ( not $card ) {
                $log->warn("Failed to create card for bug $bug->{id}");
                return;
            }

            update_whiteboard( $bug->{id}, $card->{taskid}, $whiteboard );

            push @changes, "[card created]";
        }
    }

    my $new_card = retrieve_card( $card->{taskid}, $bug->{id} );

    # Referenced card missing
    if ( not $new_card ) {
      $log->warn(
        "Card $card->{taskid} referenced in bug $bug->{id} missing, clearing kanban whiteboard");
          clear_whiteboard( $bug->{id}, $card->{taskid}, $whiteboard );
      return;
    }

    $card = $new_card;

    # Check the card extlink, if one is present, and make sure that it references the correct bug.
    my($referenced_bug) = ($card->{extlink} =~ /show_bug.cgi.*[&?]id=(\d+)/);
    if (!defined($referenced_bug)) {
        $log->warn("Bug $bug->{id} references card $card->{taskid}, but the card does not point back to a properly formatted bug.");
    } elsif ($referenced_bug ne $bug->{id}) {
        $log->warn("Bug $bug->{id} references card $card->{taskid} which references bug $referenced_bug, assigning bug $bug->{id} a new card.");

        my $found_cardid = find_card_for_bugid($bug->{id});
        if ( defined $found_cardid ) {
            # We found a usable (non-archived) card referencing this bug, so reuse it.
            $card = retrieve_card($found_cardid, $bug->{id});

            $log->warn("Bug $bug->{id} already has a card $found_cardid, updating whiteboard");

            update_whiteboard($bug->{id}, $found_cardid, $whiteboard);

            push @changes, "[bug updated]";
        } else {
            # We did not find a usable (non-archived) card referencing this bug, so open a new one.
            $log->warn("Bug $bug->{id} whiteboard << $whiteboard >> references an unknown (or archived) card, creating a new card");

            $card = create_card($bug);

            if ( not $card ) {
                $log->warn("Failed to create card for bug $bug->{id}");
                return;
            }

            update_whiteboard( $bug->{id}, $card->{taskid}, $whiteboard );

            push @changes, "[card created]";
        }
    } elsif (is_archived_card($card) && ($bug->{status} !~ /^(RESOLVED|VERIFIED)$/)) {
        # If the bug is open, and references an archived card, open a new card.
        $log->warn("Bug $bug->{id} whiteboard << $whiteboard >> references an archived card, creating a new card");

        $card = create_card($bug);

        if ( not $card ) {
            $log->warn("Failed to create card for bug $bug->{id}");
            return;
        }

        update_whiteboard( $bug->{id}, $card->{taskid}, $whiteboard );

        push @changes, "[card created]";
    }

    # Assuming we didn't just create a new card, we need to sync the existing card to match the bug.
    unless (@changes > 0 && $changes[-1] =~ /card created/) {

        #$log->debug("Syncing card $card->{taskid} extlink << $card->{extlink} >> with bug $bug->{id} whiteboard << $bug->{whiteboard} >>") if $config->verbose;

        push @changes, sync_card( $card, $bug );
    }

    my $cardid = $card->{taskid};

    if ( $config->verbose ) {
        $log->debug(sprintf "[%4d/%4d] Card %4d - Bug %8d - [%s] %s ** %s **",
          $total, $count, $cardid, $bug->{id}, $bug->{source}, $summary, "in-sync");
    }

    if (@changes) {
        foreach my $change (@changes) {
            $log->info(sprintf "[%4d/%4d] Card %4d - Bug %8d - [%s] %s ** %s **",
              $total, $count, $cardid, $bug->{id}, $bug->{source}, $summary, $change);
        }
    }
}

sub retrieve_card {
    my $card_id = shift;
    my $bug_id = shift;

    if ( exists $all_cards->{$card_id} ) {
        return $all_cards->{$card_id};
    }

    my $params = {
        history => "yes",
    };

    my $req =
      HTTP::Request->new( POST =>
"https://$WHITEBOARD_TAG.kanbanize.com/index.php/api/kanbanize/get_task_details/boardid/$BOARD_ID/taskid/$card_id/format/json"
      );

    $req->content( encode_json($params) );

    my $res = $ua->request($req);

    my $data = decode_json( $res->decoded_content );

    if ( !$res->is_success ) {
        if ( $data->{Error} eq 'No such task or board.' ) {
            return;
        }
        #XXX: Might need to clear the whiteboard or sth...
        $log->warn("Can't find card $card_id for bug $bug_id");
        return;
        #die Dumper( $data, $res );    #$res->status_line;
    }

    $all_cards->{$card_id} = $data;

    return $all_cards->{$card_id};
}

sub sync_card {
    my ( $card, $bug ) = @_;

    my @updated;

    # Check Assignee
    my $bug_assigned  = $bug->{assigned_to};
    my $card_assigned = $card->{assignee};

    # Need to convert assigned to canonical version, bugmail

    my $card_assigned_bugmail = kanbanid_to_bugmail($card->{assignee});

    if ( not defined $card_assigned ) {
        die Dumper( $bug, $card );
    }

    # Set this to 'update' if the assignees are out of sync.
    # We'll decide which way to sync using history timestamps.
    my($assignee_task) = 'none';

    if (   defined $card_assigned
        && $card_assigned ne "None"
        && $card_assigned ne 'nobody'
        && !assigned_bugzilla_email($bug_assigned)
    )
    {
        # The card is assigned, the bug is not.
        # Perhaps we need to update the bug to match the card.
        $assignee_task = 'update';
    }
    elsif ( ($bug_assigned ne $card_assigned_bugmail)
        && assigned_bugzilla_email($bug_assigned) )
    {
        my $kanbanid = bugmail_to_kanbanid($bug_assigned);
        my $bugmail = kanbanid_to_bugmail($kanbanid);

        if ($bug_assigned ne $bugmail) {
            $log->warn("[bug $bug->{id}] Bugmail user $bug_assigned not mapped to a kanban user, skipping assigned checks");
        }
        else {
            # The bug is assigned, the card doesn't match.
            # Perhaps we need to update the card to match the bug.
            $assignee_task = 'update';
        }
    }

    # Do we need to update assignees?
    if ($assignee_task eq 'update') {
        # Find out when the card and the bug were last updated.
        my $time_bug = get_bug_history_latest($bug->{id}, 'assigned_to');
        my $time_card = get_card_history_latest($card, 'assignee');

        if ($time_bug eq $time_card) {
            # This is incredibly unlikely to occur, but if it does, we'll assume the bug is correct.
            $assignee_task = 'update_bug';
        } else {
            # We have two different times. Figure out which one is newer and use it.
            my @times = ($time_bug, $time_card);
            @times = sort @times;

            if ($times[-1] eq $time_bug) {
                # The bug was updated more recently. Update the card to reflect the bug.
                $assignee_task = 'update_card';

                push @updated, "Update card assigned to $bug_assigned";
                #print STDERR
                # "bug_asigned: $bug_assigned card_assigned: $card_assigned\n";
                update_card_assigned( $card, $bug_assigned );
            } else {
                # The card was updated more recently. Update the bug to reflect the card.
                $assignee_task = 'update_bug';

                # Was the card assigned to someone, or unassigned to nobody?
                if ($card_assigned eq 'None' || $card_assigned eq 'nobody') {
                    # It was unassigned. Reset the bug to its default assignee.
                    my $error = reset_bug_assigned($bug);

                    if (!$error) {
                        $error = "**FAILED**";
                    }

                    push @updated, "Reset bug $bug->{id} assigned $error";
                } else {
                    # It was assigned. Update the bug to reflect this.
                    my $error = update_bug_assigned($bug, $card_assigned);

                    if (!$error) {
                        $error = "**FAILED**";
                    }

                    push @updated, "Update bug $bug->{id} assigned to $card_assigned $error";
                }
            }
        }

        #$log->warn(sprintf("bug << %s >> card << %s >> task << %s >>", $bug->{id}, $card->{taskid}, $assignee_task));
    }

    #Check summary (XXX: Formatting assumption here)
    my $bug_summary  = "$bug->{id} - $bug->{summary}";
    my $card_summary = $card->{title};

    if ( $bug_summary ne $card_summary ) {
        update_card_summary( $card, $bug_summary );
        push @updated, "Updated card summary ('$bug_summary' vs '$card_summary')";
    }

    # Check extlink
    my $bug_link = "https://bugzilla.mozilla.org/show_bug.cgi?id=$bug->{id}";

    if ( $card->{extlink} ne $bug_link ) {
        update_card_extlink( $card, $bug_link );
        push @updated, "Updated external link to bugzilla ( $card->{extlink} => $bug_link)";
    }

    # Check status
    my $bug_status  = $bug->{status};
    my $card_status = $card->{columnname};

    # Close card on bug completion

    # When we're done here, each of these will be either open or closed.
    my %sync_status = (
        bug  => undef,
        card => undef,
    );

    # Distill all the various complexity down to 'open' or 'closed'.
    $sync_status{bug} = ($bug_status =~ /^(RESOLVED|VERIFIED)$/) ? 'closed' : 'open';
    $sync_status{card} = ($card_status =~ /^(Done|Archive)$/) ? 'closed' : 'open';

    # Are they both open or closed?
    if ($sync_status{bug} ne $sync_status{card}) {
        # Nope.
        $log->warn("bug $bug->{id} ($sync_status{bug}) and card $card->{taskid} ($sync_status{card}) disagree");

        # We need to know when each of these objects was either opened or closed.
        my %sync_lastmod = ();

        # Load the card history.
        $card = load_card_history($card);

        # Whether the bug is open or closed, we only need to know the last time
        # its status changed.
        $sync_lastmod{bug} = get_bug_history_latest($bug->{id}, 'status');
        $sync_lastmod{bug} ||= $bug->{creation_time};

        # Whether the card is open or closed, we only need to know when it was
        # last moved to/from Done/Archive.  The API doesn't give us any hint of
        # columnname or rowname, but the latest move *is* correct. This is fine.
        $sync_lastmod{card} = get_card_history_latest($card, "moved", "(?:from|to) '(?:Done|Archive)'");
        $sync_lastmod{card} ||= get_card_history_latest($card, "task created");

        # Identify whether the bug or card was modified most recently.
        my $lastmod;

        # Make sure they have the same timetamps.
        if ($sync_lastmod{bug} eq $sync_lastmod{card}) {
            # This almost never happens. Assume the bug is correct.
            $lastmod = 'bug';
        } else {
            # Sort the timestamp labels from oldest to newest.
            my @timestamps = sort { $sync_lastmod{$a} cmp $sync_lastmod{$b} } ('bug', 'card');
            # Pick the newest label.
            $lastmod = $timestamps[-1];
        }

        # Reality check.
        die "invalid lastmod decision" unless defined $lastmod;

        $log->warn("This conflict should be resolved in favor of $lastmod ($sync_status{$lastmod}).");

        # Which side should we replicate the current status from?
        if ($lastmod eq 'bug') {
            $log->warn("Bug was modified more recently than Card.");
            if ($sync_status{'bug'} eq 'open') {
                # Bug is open. Open the card.
                $log->warn("Bug is open. Open the card.");
                reopen_card($card, $bug);
            } else {
                # Bug is closed. Close the card.
                $log->warn("Bug is closed. Close the card.");
                complete_card($card);
                my $change = "[closed card $card->{taskid} for departed bug $bug->{id}]";
                $log->info(sprintf "Card %4d - Bug %8d - [%s] %s ** %s **",
                  $card->{taskid}, $bug->{id}, $bug->{source}, $bug->{summary}, $change);
            }
        } else {
            $log->warn("Card was modified more recently than Bug.");
            if ($sync_status{'card'} eq 'open') {
                # Card is open. Open the bug.
                $log->warn("Card is open. Open the bug.");
                reopen_bug($bug, $card);
            } else {
                # Card is closed. Close the bug.
                $log->warn("Card is closed. Close the bug.");
                resolve_bug($bug, $card);
            }
        }
    }

    return @updated;
}

sub reopen_bug {
    my($bug, $card) = @_;

    update_bug_status($bug, "REOPENED");

    my $change = "[reopened bug $bug->{id} for card $card->{taskid}]";
    $log->info(sprintf "Card %4d - Bug %8d - [%s] %s ** %s **",
      $card->{taskid}, $bug->{id}, $bug->{source}, $bug->{summary}, $change);
}
sub resolve_bug {
    my($bug, $card) = @_;

    update_bug_status($bug, "RESOLVED", "FIXED");

    my $change = "[resolved (fixed) bug $bug->{id} for card $card->{taskid}]";
    $log->info(sprintf "Card %4d - Bug %8d - [%s] %s ** %s **",
      $card->{taskid}, $bug->{id}, $bug->{source}, $bug->{summary}, $change);
}

sub reopen_card {
    my($card, $bug) = @_;

    load_card_history($card);

    if ($card->{columnname} eq 'Done' && not eval { $card->{historydetails}[0]{historyevent} eq 'Task archived' }) {
        move_card( $card, $KANBANIZE_INCOMING );

        my $change = "[reopened card $card->{taskid} bug $bug->{id}]";
        $log->info(sprintf "Card %4d - Bug %8d - [%s] %s ** %s **",
          $card->{taskid}, $bug->{id}, $bug->{source}, $bug->{summary}, $change);
    } else {
        my($new_card, $source);

        # Either reusing an existing card ID, or create a new card.
        $new_card = find_card_for_bugid($bug->{id}, 1);

        # Did we find a card ID?
        if (defined($new_card)) {
            # Yes. Convert the card ID to a card object.
            $new_card = retrieve_card($new_card);
            $source = 'reused';
        } else {
            # No. Create a new card object.
            $new_card = create_card($bug);
            $source = 'created';
        }

        if ( not $new_card ) {
            $log->warn("Failed to find/create new card to reopen archived card $card->{taskid}");
            return;
        }

        $bug->{whiteboard} = update_whiteboard( $bug->{id}, $new_card->{taskid}, $bug->{whiteboard} );

        my $change = "[$source card $new_card->{taskid} bug $bug->{id} to reopen archived card $card->{taskid}]";
        $log->info(sprintf "Card %4d - Bug %8d - [%s] %s ** %s **",
          $new_card->{taskid}, $bug->{id}, $bug->{source}, $bug->{summary}, $change);
    }

    return;
}

sub unblock_card {
    my $card = shift;

    my $taskid = $card->{taskid};

    my $data = {
        boardid => $BOARD_ID,
        taskid  => $taskid,
        event   => 'unblock',
    };

    if ($DRYRUN) {
      $log->debug("unblock card");
      return;
    }

    my $req =
      HTTP::Request->new( POST =>
          "https://$WHITEBOARD_TAG.kanbanize.com/index.php/api/kanbanize/block_task/format/json"
      );

    $req->content( encode_json($data) );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        my $content = $res->content;
        my $status  = $res->status_line;
        $log->warn("Kanban API request failed while unblocking card #$taskid: $status <<< $content >>>");
    }
}

sub complete_card {
    my $card = shift;

    if ($card->{blocked} == 1) {
        # First, unblock the card, so that we can move it.
        unblock_card($card);
    }

    my $taskid = $card->{taskid};

    my $data = {
        boardid => $BOARD_ID,
        taskid  => $taskid,
        column  => 'Done',
    };

    if ($DRYRUN) {
      $log->debug("complete card");
      return;
    }

    my $req =
      HTTP::Request->new( POST =>
          "https://$WHITEBOARD_TAG.kanbanize.com/index.php/api/kanbanize/move_task/format/json"
      );

    $req->content( encode_json($data) );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        my $content = $res->content;
        my $status  = $res->status_line;
        $log->warn("Kanban API request failed while closing card #$taskid: $status <<< $content >>>");
    }
}

sub update_card_extlink {
    my ( $card, $extlink ) = @_;

    my $taskid = $card->{taskid};

    my $data = {
        boardid => $BOARD_ID,
        taskid  => $taskid,
        extlink => $extlink,
    };

    if ($DRYRUN) {
      $log->debug("update_card_extlink");
      return;
    }

    my $req =
      HTTP::Request->new( POST =>
          "https://$WHITEBOARD_TAG.kanbanize.com/index.php/api/kanbanize/edit_task/format/json"
      );

    $req->content( encode_json($data) );

    $log->debug("Updating card $taskid extlink to << $extlink >>") if $config->verbose;

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }
}

sub update_bug_status {
    my ( $bug, $status, $resolution ) = @_;

    my $bugid = $bug->{id};

    if ($DRYRUN) {
      $log->debug( "Resetting bug assigned to" );
      return;
    }

    my $req =
      HTTP::Request->new(
        PUT => "https://bugzilla.mozilla.org/rest/bug/$bugid" );

    my $content = "status=$status&token=$BUGZILLA_TOKEN";

    if ($status =~ /^(?:RESOLVED|VERIFIED|CLOSED)$/) {
        $content .= "&resolution=$resolution";
    }

    $req->content($content);

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        my $ct = $res->content_type;

        if ($ct eq 'application/json') {
            my $error;

            eval {
                $error = decode_json($res->content);
            };

            if (ref($error) eq 'HASH') {
                my $code = $error->{code};
                my $error_message = $error->{message};
                $log->error("Error no=$code talking to bugzilla: $error_message");
                return;
            }
        }

        die Dumper($res);    #$res->status_line;
    }

    return $res->is_success;
}

sub reset_bug_assigned {
    my ( $bug ) = @_;

    my $bugid = $bug->{id};

    if ($DRYRUN) {
      $log->debug( "Resetting bug assigned to" );
      return;
    }

    my $req =
      HTTP::Request->new(
        PUT => "https://bugzilla.mozilla.org/rest/bug/$bugid" );

    $req->content("reset_assigned_to=true&token=$BUGZILLA_TOKEN");

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        my $ct = $res->content_type;

        if ($ct eq 'application/json') {
            my $error;

            eval {
                $error = decode_json($res->content);
            };

            if (ref($error) eq 'HASH') {
                my $code = $error->{code};
                my $error_message = $error->{message};
                $log->error("Error no=$code talking to bugzilla: $error_message");
                return;
            }
        }


        die Dumper($res);    #$res->status_line;
    }

    return $res->is_success;
}

sub update_bug_assigned {
    my ( $bug, $assigned ) = @_;

    $assigned = kanbanid_to_bugmail($assigned);

    my $bugid = $bug->{id};

    if ($DRYRUN) {
      $log->debug( "Updating bug assigned to $assigned" );
      return;
    }

    my $req =
      HTTP::Request->new(
        PUT => "https://bugzilla.mozilla.org/rest/bug/$bugid" );

    $req->content("assigned_to=$assigned&token=$BUGZILLA_TOKEN");

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        my $ct = $res->content_type;

        if ($ct eq 'application/json') {
            my $error;

            eval {
                $error = decode_json($res->content);
            };

            if (ref($error) eq 'HASH') {
                my $code = $error->{code};
                my $error_message = $error->{message};
                $log->error("Error no=$code talking to bugzilla: $error_message");
                return;
            }
        }


        die Dumper($res);    #$res->status_line;
    }

    return $res->is_success;
}

sub update_card_summary {
    my ( $card, $bug_summary ) = @_;

    my $taskid = $card->{taskid};



    my $data = {
        boardid => $BOARD_ID,
        taskid  => $taskid,
        title   => api_encode_title($bug_summary),
    };

    if($DRYRUN) {
      $log->debug("Update card summary : $bug_summary");
      return;
    }

    my $req =
      HTTP::Request->new( POST =>
          "https://$WHITEBOARD_TAG.kanbanize.com/index.php/api/kanbanize/edit_task/format/json"
      );

    $req->content( encode_json($data) );

    $log->debug("Updating card $taskid summary to << $bug_summary >>") if $config->verbose;

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }
}

sub update_card_assigned {
    my ( $card, $bug_assigned ) = @_;

    my $taskid = $card->{taskid};

    my $assignee = bugmail_to_kanbanid($bug_assigned);

    if ($DRYRUN) {
      $log->debug("Update card assigned: $assignee");
      return;
    }

    $assignee = URI::Escape::uri_escape($assignee);

    my $req =
      HTTP::Request->new( POST =>
"https://$WHITEBOARD_TAG.kanbanize.com/index.php/api/kanbanize/edit_task/format/json/boardid/$BOARD_ID/taskid/$taskid/assignee/$assignee"
      );

    $req->content("[]");

    $log->debug("Updating card $card->{taskid} assignee to << $assignee >>") if $config->verbose;

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        warn Dumper($res);
        die $res->status_line;
    }
}

sub update_whiteboard {
    my ( $bugid, $cardid, $whiteboard ) = @_;

    if ($DRYRUN) {
      $log->debug( "Updating whiteboard" );
      return;
    }

    my $req =
      HTTP::Request->new(
        PUT => "https://bugzilla.mozilla.org/rest/bug/$bugid" );

    # Clear kanban request
    if ( $whiteboard =~ m/\[kanban:$WHITEBOARD_TAG\]/ ) {
        $whiteboard =~ s/\[kanban:$WHITEBOARD_TAG\]//;
    }

    # Clear unqualified whiteboard
    if ( $whiteboard =~ m{\[kanban:https://kanbanize.com/ctrl_board/\d+/\d+\]} ) {
        $whiteboard =~ s{\[kanban:https://kanbanize.com/ctrl_board/\d+/\d+\]}{};
    }

    # Clear old qualified whiteboards

    if ($whiteboard =~ m{kanban:$WHITEBOARD_TAG:https://kanbanize.com/ctrl_board/\d+/\d+} ) {
        $whiteboard =~ s{kanban:$WHITEBOARD_TAG:https://kanbanize.com/ctrl_board/\d+/\d+}{};
    }

    # Clear new qualified whiteboards

    if ($whiteboard =~ m{\[kanban:https://$WHITEBOARD_TAG.kanbanize.com/ctrl_board/\d+/\d+\]\s*} ) {
        $whiteboard =~ s{\[kanban:https://$WHITEBOARD_TAG.kanbanize.com/ctrl_board/\d+/\d+\]\s*}{};
    }

    $whiteboard =
      "[kanban:https://$WHITEBOARD_TAG.kanbanize.com/ctrl_board/$BOARD_ID/$cardid] $whiteboard";

    # General whitespace cleanup, so that we don't pollute the whiteboard too much.
    $whiteboard =~ s/\s+$//;

    $req->content("whiteboard=$whiteboard&token=$BUGZILLA_TOKEN");

    $log->debug("Updating whiteboard for bug $bugid to << $whiteboard >>") if $config->verbose;

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die $res->status_line;
    }

    return $whiteboard;
}

sub clear_whiteboard {
    my ( $bugid, $cardid, $whiteboard ) = @_;

    if ($DRYRUN) {
      $log->debug( "Clearing whiteboard" );
      return;
    }

    my $req =
      HTTP::Request->new(
        PUT => "https://bugzilla.mozilla.org/rest/bug/$bugid" );

    $whiteboard =~ s/\s?\[kanban:[^]]+\]\s?//g;

    $req->content("whiteboard=$whiteboard&token=$BUGZILLA_TOKEN");

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die $res->status_line;
    }

}

#XXX: https://bugzil.la/970457
sub create_card {
    my $bug = shift;

    if ($DRYRUN) {
      $log->debug( "Creating card" );
      return { taskid => 0, id => 0, };
    }

    my $data = {
        'title'    => api_encode_title("$bug->{id} - $bug->{summary}"),
        'extlink'  => "https://bugzilla.mozilla.org/show_bug.cgi?id=$bug->{id}",
        'boardid'  => $BOARD_ID,
        'priority' => $KANBANIZE_PRIORITY,
    };

    my $req =
      HTTP::Request->new( POST =>
"https://$WHITEBOARD_TAG.kanbanize.com/index.php/api/kanbanize/create_new_task/format/json"
      );

    $req->content( encode_json($data) );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        $log->error( "can't create card:" . $res->status_line );
        die Dumper($res);
        return;
    }

    my $card = decode_json( $res->decoded_content );

    $card->{taskid} = $card->{id};

    move_card( $card, $KANBANIZE_INCOMING );

    return $card;
}

sub move_card {
    my ( $card, $lane ) = @_;

    if ($DRYRUN) {
      $log->debug( "Moving card to $lane" );
      return;
    }

    my $data = {
        boardid => $BOARD_ID,
        taskid  => $card->{taskid},
        column  => 'Backlog',
        lane    => $lane,
    };

    my $req =
      HTTP::Request->new( POST =>
          "https://$WHITEBOARD_TAG.kanbanize.com/index.php/api/kanbanize/move_task/format/json"
      );

    $req->content( encode_json($data) );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);
    }

}

sub get_bug_info {
    my $bugid = shift;
    my $data =
      get("https://bugzilla.mozilla.org/rest/bug/$bugid?token=$BUGZILLA_TOKEN");

    if ( not $data ) {
        $log->error( "Failed getting Bug info for Bug $bugid from bugzilla" );
        return { id => $bugid, error => "No Data" };
    }

    $log->debug("Retrieving info for Bug $bugid from bugzilla");

    $data = decode_json($data);

    return $data->{bugs}[0];
}

sub parse_whiteboard {
    my $whiteboard = shift;

    my $card;

    #XXX: Unqualified kanmban tag, need to handle...
    if ( $whiteboard =~
        m{\[kanban:https://kanbanize.com/ctrl_board/(\d+)/(\d+)\]} )
    {
        my $boardid = $1;
        my $cardid  = $2;

        if ($BOARD_ID ne $boardid) {
          $log->warn( "Found a card from a mismatched board:$boardid" );
          return undef;
        }

        $card = { taskid => $cardid };
    }
    elsif ( $whiteboard =~
        m{\[kanban:https://$WHITEBOARD_TAG.kanbanize.com/ctrl_board/(\d+)/(\d+)\]} )
    {
        my $boardid = $1;
        my $cardid  = $2;

        if ($BOARD_ID ne $boardid) {
          $log->warn( "Found a card from a mismatched board:$boardid" );
          return undef;
        }

        $card = { taskid => $cardid };
    }
    elsif ( $whiteboard =~ m{\[kanban:ignore\]} ) {
      $log->info( "Should ignore this card!" );
      $card = {
        ignore => 1,
        taskid => 0 
      };
    }

    return $card;
}

sub assigned_bugzilla_email {
  my $mail = shift;

  my $assigned = 1;

  if ($mail =~ m/\@.*\.bugs$/) {
    $assigned = 0;
  }

  if ($mail eq 'nobody@mozilla.org') {
    $assigned = 0;
  }

  return $assigned;
}

sub bugmail_to_kanbanid {
  my $bugmail = shift;
  my $kanbanid;

  if (exists $BUGMAIL_TO_KANBANID{$bugmail}) {
    $kanbanid = $BUGMAIL_TO_KANBANID{$bugmail};
  }
  elsif ($bugmail =~ /\@mozilla.com$/) {
    ( $kanbanid = $bugmail ) =~ s/\@.*//;
  }
  else {
    $kanbanid = 'None';

    $log->debug("Unable to convert bugmail $bugmail to a valid kanbanid, resorting to 'None'.");
  }

  return $kanbanid;
}


sub kanbanid_to_bugmail {
  my $kanbanid = shift;
  my $bugmail;

  if (exists $KANBANID_TO_BUGMAIL{$kanbanid}) {
    $bugmail = $KANBANID_TO_BUGMAIL{$kanbanid}
  }
  else {
    $bugmail = "$kanbanid\@mozilla.com";
  }

  return $bugmail;
}

sub api_encode_title ($) {
    my $title = shift;
    # Kanbanize requires a backslash to be present within the title value.
    $title =~ s/\"/\\\"/g;
    # Kanbanize requires URI escaping of only the title, but no other elements.
    $title = URI::Escape::uri_escape($title);
    return $title;
}

1;

=head1 SYNOPSIS

Kanbanize Bugzilla Sync Tool

=head1 METHODS

=head2 new

This method does something experimental.

=head2 version

This method returns a reason.

