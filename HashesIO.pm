package HashesIO;

###################################################################
# HashesIO
#
# Package with IO routines for storing and reading hashes to file
# 
#  Author: Giuseppe Narzisi 
#    Date: December 11, 2013
#
###################################################################

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(loadLoc2KeyMerge loadLoc2Key printLoc2key loadRefCovMerge printRefCov loadCov loadDB mergeDBs);

use strict;
use warnings;
use FindBin qw($Bin);
use lib $Bin; # add $Bin directory to @INC
use Utils;

#use Tie::Cache;
use MLDBM::Sync;                       # this gets the default, SDBM_File
use MLDBM qw(DB_File Storable);        # use Storable for serializing
use MLDBM qw(MLDBM::Sync::SDBM_File);  # use extended SDBM_File, handles values > 1024 bytes
use Fcntl qw(:DEFAULT);                # import symbols O_CREAT & O_RDWR for use with DBMs

## load coverage info
##########################################
sub loadCov {
	
	my $covFile = $_[0];
	my $hash = $_[1];

	#my $FILE = new IO::Uncompress::Gunzip "$covFile.gz" or die "IO::Uncompress::Gunzip failed: $GunzipError\n";
  	open FILE, "gunzip -c $covFile.gz|" or die "Can't open $covFile.gz ($!)\n!";
  
	while (<FILE>) {
		chomp;
		my ($chr, $pos, $cov) = split /\t/, $_, 3;
		my $key = "$chr:$pos";
		$hash->{$key} = $cov;
	}
	close FILE;
}

# Merge mutliple variants DBs 
#####################################################
sub mergeDBs {
	
	#mergeDBs(\%$hash, $dbm_obj, $count, $WORK);
	
	my $hash = $_[0];
	my $dbm_obj = $_[1];
	my $count = $_[2];
	my $WORK = $_[3];
	
	print STDERR "Merge DBs...\n";

	$dbm_obj->Lock;
	
	#update statistics in the database
	if(exists $hash->{stats})  { 
		my $sts = $hash->{stats}; 
		$sts->{num_exceptions} = 0;
		$sts->{num_dfs_limit} = 0;
		$sts->{num_partial_align} = 0;
		$sts->{num_with_cycles} = 0;
		$sts->{num_ok} = 0;
		$hash->{stats} = $sts;
	}
	
	for(my $i = 1; $i <= $count; $i++) {
	
		my %hash_i;
		my $dbm_obj_i = tie %hash_i, 'MLDBM::Sync', "$WORK/variants.$i.db", O_CREAT|O_RDWR, 0640;
		$dbm_obj_i->Lock;
		
		foreach my $key (keys %hash_i) {
			next if($key eq "stats"); # skip stats info
			
			my $mut = $hash_i{$key};
			if( !(exists $hash->{$key}) ) {
				$hash->{$key} = $mut;
			}
			else { # denovo already in the table
				# update the coverage to the highest value found so far
				my $mut_old = $hash->{$key};
				if ($mut_old->{avgcov} < $mut->{avgcov}) { $mut_old->{avgcov} = $mut->{avgcov}; } # max avg coverage
				if ($mut_old->{mincov} < $mut->{mincov}) { $mut_old->{mincov} = $mut->{mincov}; } # max min coverage
				$hash->{$key} = $mut_old;
			}
		}

		#update statistics in the database
		my $stats_i;
		if(exists $hash_i{stats}) { $stats_i = $hash_i{stats}; }

		if( !(exists $hash->{stats}) ) { 
			$hash->{stats} = $stats_i;
		}
		else { 
			my $old_stats = $hash->{stats}; 
			$old_stats->{num_repeats} += $stats_i->{num_repeats};
			$old_stats->{num_exceptions} += $stats_i->{num_exceptions};
			$old_stats->{num_dfs_limit} += $stats_i->{num_dfs_limit};
			$old_stats->{num_partial_align} += $stats_i->{num_partial_align};
			$old_stats->{num_with_cycles} += $stats_i->{num_with_cycles};
			$old_stats->{num_ok} += $stats_i->{num_ok};
			$hash->{stats} = $old_stats;
		}
		$dbm_obj_i->UnLock;
		
		runCmd("delete DB", "rm $WORK/variants.$i.db.*"); # delete DB
	}
	
	$dbm_obj->UnLock;
}

# Load coverage information from files
#####################################################
sub loadRefCovMerge {

	my $ref_hash = $_[0];
	my $count = $_[1];
	my $WORK = $_[2];
	
	print STDERR "Load reference coverage...\n";
	
	my $num_updates = 0;	
	for(my $i = 1; $i <= $count; $i++) {
	
		my $file = "$WORK/refcov.$i.txt";
		open FILE, "< $file" or die "Can't open $file ($!)\n";

		while (<FILE>) {
			chomp;
						
			# format:
			# [key, refCov]
			my ($key, $refCov) = split /\t/, $_, 6;
						
			if ( (exists $ref_hash->{$key}) ) { # already in the table			
				my $cov = $ref_hash->{$key};
				if ($cov < $refCov) { $cov = $refCov; $num_updates++; } # max coverage
				$ref_hash->{$key} = $cov;
			}
			else { # not in the table
				$ref_hash->{$key} = $refCov;
			}
		}
		close FILE;
		runCmd("delete file", "rm $WORK/refcov.$i.txt");
	}
	
	#print STDERR "Num. of updates: $num_updates\n";
}

## print reference coverage to file
##########################################
sub printRefCov {
	
	my $outFile = $_[0];
	my $hash = $_[1];
	
	print STDERR "Printing reference coverage to file...\n";
	
	if (-e "$outFile.gz") {
		runCmd("delete refcov file", "rm $outFile.gz");		
	}
	open FILE, "> $outFile" or die "Can't open $outFile ($!)\n";
	
	foreach my $key (keys %$hash) {
	#foreach my $key (sort { bypos($a,$b) } keys %$hash) {
		my ($chr, $pos) = split /:/, $key, 2;
		my $cov = $hash->{$key};
		print FILE "$chr\t$pos\t$cov\n";
	}
	
	close FILE;
	
	# compress reference coverage file
	runCmd("gzip", "gzip $outFile");
}

sub bypos {
	my ($a, $b) = @_;
	my $result;
	my ($chr1, $pos1) = split /:/, $a, 2;
	my ($chr2, $pos2) = split /:/, $b, 2;
	if ( ($chr1 =~ m/^-?\d+\z/) && ($chr2 =~ m/^-?\d+\z/) ) {
		$result = ( ($chr1 <=> $chr2) || ($pos1 <=> $pos2) );
	}
	else {
		$result = ( ($chr1 cmp $chr2) || ($pos1 <=> $pos2) );
	}
	return $result;
}

## load loc2keys from file
#####################################################
sub loadLoc2Key {
	
	my $file = $_[0];
	my $l2k = $_[1];
	
	open FILE, "gunzip -c $file|" or die "Can't open $file ($!)\n!";
	
	while (<FILE>) {
		chomp;
			
		# format:
		# [loc refcov key1 key2 key3 ...]
		my @array =  split /\t/, $_;
		my $loc = shift @array;
		my $refCov = shift @array;
		$l2k->{$loc}->{refCov} = $refCov;
		foreach my $key (@array) { push @{$l2k->{$loc}->{keys}}, $key; }
	}
	close FILE;
}

# Load and combine mutations by location from multiple files
#####################################################
sub loadLoc2KeyMerge {
	
	my $l2k_hash = $_[0];
	my $refcov_hash = $_[1];
	my $count = $_[2];
	my $kmer = $_[3];
	my $WORK = $_[4];
	
	print STDERR "Load loc2keys DB...\n";
	
	my $num_updates = 0;	
	for(my $i = 1; $i <= $count; $i++) {
	
		my $file = "$WORK/loc2keys.$i.txt";
		open FILE, "< $file" or die "Can't open $file ($!)\n";

		my @keys;
		while (<FILE>) {
			chomp;
			
			# format:
			# [loc key1 key2 key3 ...]
			my @array =  split /\t/, $_;
			my $loc = shift @array;
			
			$l2k_hash->{$loc}->{refCov} = 0;
			
			# get reference coverage
			if(exists $refcov_hash->{$loc}) {
				my $minCov = $refcov_hash->{$loc};
				my ($chr, $pos) = split /:/, $loc, 2;				
				for (my $t = $pos; $t<($pos+$kmer+1); $t++) { # compute min coverage over window of size K
					my $loc2 = "$chr:$t";
					if (exists $refcov_hash->{$loc2}) {
						my $c = $refcov_hash->{$loc2};
						if( ($c > 0) && ($c < $minCov) ) { $minCov = $c; }
					}
				}
				
				$l2k_hash->{$loc}->{refCov} = $minCov;
			}
			
			foreach my $key (@array) { push @{$l2k_hash->{$loc}->{keys}}, $key; }
		}
		close FILE;
		runCmd("delete file", "rm $WORK/loc2keys.$i.txt");
	}
	
	# remove duplicates
	foreach my $loc (keys %$l2k_hash) {
		my @uniq_list = uniq(@{$l2k_hash->{$loc}->{keys}});
		@{$l2k_hash->{$loc}->{keys}} = @uniq_list;
	}
}

## print loc2keys to file
##########################################
sub printLoc2key {
	
	my $outFile = $_[0];
	my $hash = $_[1];
	
	print STDERR "Printing loc2key DB to file...\n";
	
	if (-e "$outFile.gz") {
		runCmd("delete refcov file", "rm $outFile.gz");		
	}
	
	open FILE, "> $outFile" or die "Can't open $outFile ($!)\n";
	foreach my $loc (keys %$hash) {
		print FILE "$loc\t";
		if ( exists($hash->{$loc}->{refCov}) ) {
			print FILE "$hash->{$loc}->{refCov}\t";
		}

		if ( exists($hash->{$loc}->{keys}) ) {
			foreach my $key ( @{$hash->{$loc}->{keys}} ) {
				print FILE "$key\t";
		 	}
		}
		print FILE "\n";
	}
	close FILE;
	
	# compress reference coverage file
	runCmd("gzip", "gzip $outFile");
}

## load list of variants from data-base
##########################################
sub loadDB {
	
	my $dbFile = $_[0];
	my $hash = $_[1];
	my $exons = $_[2];
	my $intarget = $_[3];
	my %db;
	
	my $out = 1;
	if(!-e "$dbFile.dir") { 
		$out = -1; 
		print STDERR "ERROR: $dbFile not found!\n";
	}
	else {
		
		my $dbm_obj = tie %db, 'MLDBM::Sync', $dbFile, O_RDONLY, 0640 or print STDERR "Tie unsuccesful!\n";
	
		# tie once to database, read/write as much as necessary
	    $dbm_obj->Lock;

		my $num_snp=0;
		my $num_ins=0;
		my $num_del=0;
		my $num_tot=0;
		
		#make a copy of the DB hash for fast sorting
		foreach my $key (keys %db) {
		
			next if($key eq "stats"); # skip stats info
		
			my $mut = $db{$key};
			#update chromosome name to correctly sort the variants
			#my $chr = $mut->{chr};
			#if ($chr =~ /chr/) { $mut->{chr} = substr($chr,3); }
			#if ($chr =~ /chr\w*(\w+)/) { $variants{$key}->{chr} = $1; }
		
			if($intarget) { # export if intarget true
				next if(inTarget($mut, $exons) eq "false");
			}		
			$hash->{$key} = $mut; 
			
			my $t = $mut->{type};
			if($t eq "snp") { $num_snp++; }
			if($t eq "ins") { $num_ins++; }
			if($t eq "del") { $num_del++; }
			$num_tot++;
		}
		$dbm_obj->UnLock;
		
		#print STDERR "[#SNPs: $num_snp | #Ins: $num_ins | #Del: $num_del | Tot: $num_tot]\n";
	}

	return $out;
}

1;
