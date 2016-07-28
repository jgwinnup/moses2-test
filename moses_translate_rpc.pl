#!/usr/bin/perl

use strict;
use lib 'tools/cpan/share/perl5';
use XMLRPC::Lite;
use Getopt::Long;
use IO::Handle;
use POSIX ":sys_wait_h";
use Encode;

binmode(STDIN, ":utf8");

my $PROGRAM = $0;
$PROGRAM =~ s/^.*\///;

my $USAGE = "\n" .
   " $PROGRAM - translate pre-processed text using a moses server\n\n" .
   "  usage:\n" .
   "     $PROGRAM [options]  url  [infile]\n" .
   "  options:\n" .
   "     --outfile    file   Write the output to file (default=stdout)\n" .
   "     --maxjobs    int    Maximum number of translation jobs (default=4)\n" .
   "     --help              Prints this message\n" .
   "  url:\n" .
   "     url of the moses server\n" .
   "  infile:\n" .
   "     pre-processed text file (default=stdin)\n\n";

our $soap_error_count = 0;

my @CHARS = ("1","2","3","4","5","6","7","8","9","0","q","w","e","r","t","y","u","i","o","p","a","s","d","f","g","h","j","k","l","z","x","c","v","b","n","m","Q","W","E","R","T","Y","U","I","O","P","A","S","D","F","G","H","J","K","L","Z","X","C","V","B","N","M");

{
   my $url = undef;
   my $in_file = undef;
   my $fh = undef;
   my $line = undef;
   my $line_num = 0;
   my $result = undef;
   my $proxy = undef;
   my $status = undef;
   my $text = undef;
   my $pid = undef;
   my @child_pids = ();
   my @temp = ();
   my @output = ();
   my %param = ();
   my %unknown_map = ();

   # read the command line options
   my %opts = (
      "maxjobs" => 4,
      "outfile" => undef,
      "help" => 0,
   );
   GetOptions(\%opts, "outfile=s", "maxjobs=i", "help");
   die($USAGE) if($opts{help} || (scalar(@ARGV) < 1) || (scalar(@ARGV) > 2));
   ($url, $in_file) = @ARGV;

   if(defined($in_file)) {
      open($fh, "<:utf8", $in_file) or die("ERROR reading $in_file\n");
   } else {
      $fh = \*STDIN;
   }

   # pipe for communicating between the parent and child processes
   pipe(PARENT_RDR, CHILD_WTR);
   CHILD_WTR->autoflush(1);
   binmode(CHILD_WTR, ":utf8");

   # moses XMLRPC service
   $proxy = XMLRPC::Lite->proxy($url);
   $proxy->on_fault(
      sub {
         my $soap = shift;
         my $res = shift;
         if( ref($res)) {
            warn($res->faultstring . "\n");
         } else {
            warn($soap->transport->status . "\n");
         }
         $soap_error_count++;
         return new SOAP::SOM;
      }
   );

   # read the text file
   while(<$fh>) {
      chomp;
      $line = $_;

      # skip blank lines
      if($line =~ /^(\s+)?$/) {
         $output[$line_num] = "";
         $line_num++;
         next;
      }

      # start a new child process
      $pid = fork();
      unless(defined($pid)) {
         die("ERROR creating a child process\n");
      }
      push @child_pids, $pid;

      # child process
      if($pid == 0) {
         close(PARENT_RDR);

         $line = map_tokens($line, \%unknown_map);

         # translate the text
         %param = ("text" => SOAP::Data->type(string => $line));
         $result = $proxy->call("translate", \%param)->result;
         $text = pack('U*', unpack('C*', $result->{'text'}));

         $text = unmap_tokens($text, \%unknown_map);

         # send the result back to the parent process
         if($soap_error_count) {
            print CHILD_WTR "ERROR\n";
         } else {
            print CHILD_WTR "$line_num $text\n";
         }
         close(CHILD_WTR);

         # finished
         exit(0);
      }

      # check how many jobs are currently processing
      if(scalar(@child_pids) == $opts{maxjobs}) {
         @temp = ();
         foreach $pid (@child_pids) {
            $status = waitpid($pid, WNOHANG);

            # error occurred
            if($status == -1) {
               die("ERROR processing fork() pid $pid\n");

            # job finished
            } elsif($status != 0) {
               parent_read(\@output);

            # job is still running
            } else {
               push @temp, $pid;
            }
         }
         @child_pids = @temp;

         # if needed, wait until a job finishes
         if(scalar(@child_pids) == $opts{maxjobs}) {
            $status = wait();

            # error occurred
            if($status == -1) {
               die("ERROR processing wait() on child processes\n");
            }
            parent_read(\@output);

            @child_pids = grep {$_ != $status} @child_pids;
         }
      }
      $line_num++;
   }
   close($fh);

   # wait until all jobs have finished
   foreach $pid (@child_pids) {
      $status = waitpid($pid, 0);

      # error occurred
      if($status == -1) {
         die("ERROR processing fork() pid $pid\n");
         return(0);
      }
      parent_read(\@output);
   }

   # create the output file
   if(defined($opts{'outfile'})) {
      open($fh, ">$opts{outfile}") or die("ERROR creating $opts{outfile}\n");
   } else {
      $fh = \*STDOUT;
   }
   print $fh join("\n", @output) . "\n";
   close($fh);
}

sub parent_read{
   my $ref = shift;
   my $line = undef;
   my $line_num = undef;
   my $text = undef;

   chomp($line = <PARENT_RDR>);
   ($line_num, $text) = split(' ', $line, 2);
   unless($line_num =~ /^\d+$/) {
      return;
   }
   $$ref[$line_num] = $text;
}

sub map_tokens{
   my $line = shift;
   my $ref = shift;
   my $utf8_line = Encode::decode_utf8($line);
   my $token = undef;
   my $unknown_id = undef;
   my @tokens = ();

   # clear the hash
   %$ref = ();

   # check for UTF-8 characters not from plane 0
   if($utf8_line =~ /[\x{10000}-\x{10ffff}]/) {
      @tokens = split(' ', $utf8_line);
      foreach $token (@tokens) {
         if($token =~ /[\x{10000}-\x{10ffff}]/) {
            $unknown_id = get_unknown_id($ref);
            $$ref{$unknown_id} = $token;
            warn("WARNING marking token $token as unknown\n");
            $token = $unknown_id;
         }
      }
      $line = Encode::encode_utf8(join(" ", @tokens));
   }
   return($line);
}

sub unmap_tokens{
   my $line = shift;
   my $ref = shift;
   my $token = undef;
   my $unknown_id = undef;
   my $unmap = undef;
   my @tokens = ();

   if(keys %$ref) {
      @tokens = split(' ', $line);
      foreach $token (@tokens) {
         if(exists($$ref{$token})) {
            $unknown_id = $token;
            $token = $$ref{$unknown_id};
            $$ref{$unknown_id} = undef;
         }
      }
      $line = join(" ", @tokens);
      foreach $token (keys %$ref) {
         if(defined($$ref{$token})) {
            warn("WARNING did not find token $token\n");
            $line =~ s/$token/$$ref{$token}/;
         }
      }
   }
   return($line);
}

# this is major overkill, but better safe than sorry
sub get_unknown_id{
   my $line = shift;
   my $line_num = shift;
   my $unknown_map_ref = shift;
   my $unknown_id = undef;
   my $try = 0;
   my %tokens = ();

   # store all tokens in a hash
   foreach (split(' ', $line)) {
      $tokens{$_} = undef;
   }

   # shuffle the character array and create an unknown id
   fisher_yates_shuffle(\@CHARS);
   $unknown_id = join("", @CHARS);
   while(exists($$unknown_map_ref{$line_num}{$unknown_id}) || exists($tokens{$unknown_id})) {
      fisher_yates_shuffle(\@CHARS);
      $unknown_id = join("", @CHARS);
      $try++;
      if($try > 100) {
         die("ERROR could not create an unknown id for line $line\n");
      }
   }
   return($unknown_id);
}

# random permutation of an array
sub fisher_yates_shuffle{
   my $arr_ref = shift;
   my $i = undef;
   my $j = undef;

   $i = scalar(@$arr_ref);
   while($i--) {
      $j = int(rand($i+1));
      next if($i == $j);
      @$arr_ref[$i, $j] = @$arr_ref[$j, $i];
   }
}
