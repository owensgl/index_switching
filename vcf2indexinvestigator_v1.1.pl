#!/bin/perl
use strict;
use warnings;
use Getopt::Long;

my $min_dp = 5; #minimum depth of unbalanced allele;
my $max_sites = 500000;
my $popinfo = "NOTSPECIFIED";

GetOptions (
        "info=s" => \$popinfo,
        "max_sites=i"   => \$max_sites,
        "min_dp=i"  => \$min_dp
                );

print STDERR "Using info file $popinfo\n";
print STDERR "Calculating for $max_sites sites\n";
print STDERR "Unblanaced heterozygotes require >=$min_dp reads\n";

sub fisher_yates_shuffle
{
    my $array = shift;
    my $i = @$array;
    while ( --$i )
    {
        my $j = int rand( $i+1 );
        @$array[$i,$j] = @$array[$j,$i];
    }
}



my $min_unbalanced_dp = 1;
my %lane;
my %tech;
my %reads;
my %total_lanes;
open POP, $popinfo or die "ERROR: Can't open sample info file: $!";
my %lanes_per_sample;
while(<POP>){
  chomp;
  if ($. == 1){next;}
  my @a = split(' ',$_);
  my $sample = $a[0];
  my $lane = $a[1];
  my $tech = $a[2];
  foreach my $i (1..100){
    unless($lane{$sample}{$i}){
      $lane{$sample}{$i} = $lane;
      goto MOVEON;
    }
  }
  MOVEON:
  $tech{$sample} = $tech;
  $total_lanes{$lane}++;
  $lanes_per_sample{$sample}++;
}

my $n_of_lanes = scalar(keys %total_lanes);
if ($n_of_lanes <= 1){die "ERROR: This program needs more than one lane of data to work\n";}
close POP;
my $counter;
my %sample;

print "site\tsample\ttechnology\tlanes\tdepth\tpercent\ttype\tvalue";
while(<STDIN>){
  my $line = "$_";
  chomp $line;
  my @fields = split /\t/,$line;
  if($line=~m/^##/){
    next;
  }
  if ($line =~m/^#CHROM/){
    my $first_line;
    foreach my $i (9..$#fields){
      $sample{$i} = $fields[$i];
    }
  }
  else{
    $counter++;
    if ($counter > $max_sites){goto ENDSCRIPT;}
    if ($counter % 100000 == 0){print STDERR "Processed $counter sites\n";}
    my $chr = $fields[0];
    my $pos = $fields[1];
    my $alt = $fields[4];
    my $multi_alt;
    my @alts;
    @alts = split(/,/,$alt);
    if (length($alt) > 1){
      next;
    }
    my @test_samples;
    my %lane_alleles;
    my %total_alleles;
    my %sample_alleles;
    my %rare_allele;
    my %test_depth;
    my %counts_in_sample;
    my %het;
    my $total_count;
    my $format = $fields[8];
    my $format_type;
    if ($format =~ m/^GT:DP:DPR:/){
      $format_type = "fb";
    }elsif ($format =~ m/^GT:AD:DP/){
      $format_type = "gatk";
    }else{
      die "unrecognized vcf genotype format $format\n";
    }
    #Look for samples with unbalanced alleles
    foreach my $i (9..$#fields){
      unless($lane{$sample{$i}}{1}){
	next;
      }
      if ($fields[$i] ne '.'){
        my @info = split(/:/,$fields[$i]);
        my $call = $info[0];
        my @bases = split(/\//,$call);
	foreach my $j (1..$lanes_per_sample{$sample{$i}}){
          $lane_alleles{$lane{$sample{$i}}{$j}}{$bases[0]}++;
          $lane_alleles{$lane{$sample{$i}}{$j}}{$bases[1]}++;
        }
        $sample_alleles{$sample{$i}}{1} = $bases[0];
        $sample_alleles{$sample{$i}}{2} = $bases[1];
        $counts_in_sample{$sample{$i}}{$bases[0]}++;
        $counts_in_sample{$sample{$i}}{$bases[1]}++;
        $total_alleles{$bases[0]}++;
        $total_alleles{$bases[1]}++;
	$total_count+=2;
	if ($bases[0] ne $bases[1]){
	  $het{$sample{$i}} = "T";
	}
        my $dp;
        my $ref_dp;
        my $alt_dp;
        if ($format_type eq "fb"){
          $dp = $info[1];
          $ref_dp = $info[3];
          $alt_dp = $info[5];
        }elsif ($format_type eq "gatk"){
          $dp = $info[2];
          my @tmp = split(/,/,$info[1]);
	  $ref_dp = $tmp[0];
	  $alt_dp = $tmp[1];
        }
	if ($dp eq "\."){$dp = 0;}
        if ($dp >= $min_dp){
          if ($ref_dp == $min_unbalanced_dp){
            push(@test_samples,$sample{$i});
            $rare_allele{$sample{$i}} = 0;
            $test_depth{$sample{$i}} = $dp;
          }elsif ($alt_dp == $min_unbalanced_dp){
            push(@test_samples,$sample{$i});
            $rare_allele{$sample{$i}} = 1;
            $test_depth{$sample{$i}} = $dp;
          }
        }
      }
    }
      unless (@test_samples){next;}
      foreach my $test_sample (@test_samples){
        my %testlanes;
	foreach my $j (1..$lanes_per_sample{$test_sample}){
          $testlanes{$lane{$test_sample}{$j}}++;
        }
	my $n;
	foreach my $i (9..$#fields){ #Count each sample in the lane that has data to make it equal $n
          unless ($lane{$sample{$i}}{1}){next;}
	  if ($test_sample eq $sample{$i}){next;}
          foreach my $k (1..$lanes_per_sample{$sample{$i}}){
            if ($testlanes{$lane{$sample{$i}}{$k}}){
	      $n++;
	      goto NEXTSAMPLE;
            }
	  }
          NEXTSAMPLE:
	}
#print STDERR "$chr.$pos\t$test_sample\t$n\n";
        my $picked_samples = 0;
        my %control_alleles;
        my $tmp_counter = 0;
	my @range = (9..$#fields);
	fisher_yates_shuffle(\@range);	
        foreach my $rand (@range){
          my $matched;
          if ($sample{$rand} eq $test_sample){next;}
	  unless($lane{$sample{$rand}}{1}){next;}
          unless(defined $sample_alleles{$sample{$rand}}{1}){next;}
          #If correct technology and lane
          if ($tech{$sample{$rand}} eq $tech{$test_sample}){
            foreach my $k (1..$lanes_per_sample{$sample{$rand}}){
              foreach my $j (1..$lanes_per_sample{$test_sample}){
                if ($lane{$test_sample}{$j} eq $lane{$sample{$rand}}{$k}){
                  $matched++;
                }
              }
            }
          }
          unless ($matched){
            $picked_samples++;
            $control_alleles{$sample_alleles{$sample{$rand}}{1}}++;
            $control_alleles{$sample_alleles{$sample{$rand}}{2}}++;
#print STDERR "picked random sample $rand, which is $picked_samples\n";
#print STDERR "This sample had $sample_alleles{$sample{$rand}}{1} and $sample_alleles{$sample{$rand}}{2}\n";
          }
	  if ($picked_samples >= $n){
	    goto TESTSAMPLE;
	  }
        }
	TESTSAMPLE:
	if ($picked_samples ne $n){next;}
        #check if unbalanced allele is in the lane
        my $lane_present = "0";
        my %lane_tmp;
        foreach my $j (1..$lanes_per_sample{$test_sample}){
          $lane_tmp{$j} = $lane_alleles{$lane{$test_sample}{$j}}{$rare_allele{$test_sample}};
          if ($counts_in_sample{$test_sample}{$rare_allele{$test_sample}}){
            $lane_tmp{$j}-=$counts_in_sample{$test_sample}{$rare_allele{$test_sample}};
          }
          if ($lane_tmp{$j}){
            $lane_present = "1";
          }
        }

        #check if unbalanced allele is in the random non-lane samples
        my $control_present = "0";
        if ($control_alleles{$rare_allele{$test_sample}}){
          $control_present = "1";
        }
	my $test_sample_freq = 0;
	if ($counts_in_sample{$test_sample}{$rare_allele{$test_sample}}){
	  $test_sample_freq = $counts_in_sample{$test_sample}{$rare_allele{$test_sample}};
	}
	unless($total_alleles{$rare_allele{$test_sample}}){
	  $total_alleles{$rare_allele{$test_sample}} = 0;
	}
	unless($total_alleles{0}){
	  $total_alleles{0} = 0;
	}
	unless($total_alleles{1}){
	  $total_alleles{1} = 0;
	}
        my $percent_unbalanced = (($total_alleles{$rare_allele{$test_sample}} - $test_sample_freq) / ($total_count - 2));
#print STDERR "$percent_unbalanced\t";
        #Calculate chance that you will have the allele in your lane given the allele freq and number of samples
        my $chance = 1 - (1 - $percent_unbalanced)**($n*2);
#print STDERR "$chance\t$n\t$lane{$test_sample}{1}\n";
	if ($chance > .95){next};
#print STDERR "percent = $percent_unbalanced, n = $n, chance = $chance\n";
        my $all_lanes = $lane{$test_sample}{1};
        if ($lane{$test_sample}{2}){
          foreach my $j (2..$lanes_per_sample{$test_sample}){
            $all_lanes .= ";$lane{$test_sample}{$j}";
          }
        }
        print "\n$chr.$pos\t$test_sample\t$tech{$test_sample}\t$all_lanes\t$test_depth{$test_sample}\t$chance\twithin_lane\t$lane_present";
        print "\n$chr.$pos\t$test_sample\t$tech{$test_sample}\t$all_lanes\t$test_depth{$test_sample}\t$chance\tcontrol\t$control_present";
      }
    }
}
ENDSCRIPT:
