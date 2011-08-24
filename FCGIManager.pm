#!/usr/bin/perl

#
# (c) 2001 Sebastian Boehm
#
#
#
#features
#
# - forks new childs , instead of starting new childs (traditional FCGI-processmanager)
# - saves much memory ( COW ) 
# - over the time, the content of the caches may change, so after a certain time, we replace all childs with new childs from the same parent -> so COW will stay efficient over a long period
# - tunealbles :
#    - minSpares = when less than $minSpares idle processes available we fork new processes
#    - maxSpares = when more than $maxSpares idle processes available we teminate processes
#    -> by giving min and max a good range you can prevent jitter
#    - maxInstances = the top limit for creating new processes
#    - reSpwanInterval = the time interval in seconds, by which all childs get replaced by new ones
# - portable: you can use it in any kind of FCGI application
#
# 
#
# usage example: 
#
# use FCGIManager;
# 
# &FCGIManager::initializeFCGI(
#	'requestCallback' => \&request,
#	'preForkCallback' => \&preFork, -> optional
#	'postForkCallback' => \&postFork, -> optional
#	'minSpares' => 0,
#	'maxSpares' => 0,
#	'maxInstances' => 1,
#	'reSpawnInterval' => '3600',
#	'ipcKey' => $$ -> 
# );
# &FCGIManager::runFCGI;
#
#
# for childless-mode no initialization needed
# &FCGIManager::runSingleFCGI(\&request);
#
#

package MyCGI;
use CGI qw(-compile :cgi);
@ISA = ('CGI');
# overload method for making CGI.pm usable with FCGI
sub save_request { }
# workaround for libfcgi bug
while (($ignore) = each %ENV) { }


package FCGIManager;

use FCGI;
use IO::Handle;


use strict;
use Storable;
use IPC::ShareLite;
use Time::HiRes qw(time sleep);
use POSIX;


my $debug = 'false';
my $debugverbose = 'false';



my $minSpares = 2;
my $maxSpares = 4;
my $maxInstances = 10;
my $reSpawnInterval = 0;
my $lastReSpawn = time;
my $role = 'master';
my $globalState = {};
my $share;
my $ipckey = 100;
my $last_request = time;
my $count = 0;
my $preForkCallback = sub{};
my $postForkCallback = sub{};
my $requestCallback = sub{print "Content-Type: text/plain\r\n\r\nFCGI not initialized!\r\n"; die 'FCGI not initialized!'};
my $afterRequestCallback = undef;

my $masterpid = $$;

$SIG{'CHLD'}='IGNORE';

#
# REMOVED THE ALARM, CAUSE IT CAUSES "INTERNAL SERVER ERROR" WITH 'SAFE SIGNALS' IN PERL > 5.7.3
#
#$SIG{'ALRM'} = sub 
#{ 
#	if((&manageProcesses eq 'quit')and($role eq 'slave'))
#	{
#		warn('FCGIMgr removed idle worker '.$$)if $debug eq 'true';
#		&stateLock;
#		delete $globalState->{$$};
#		&stateUnlock;
#		exit;
#	}
#};

close STDOUT;

my $count;
my $out = new IO::Handle;
my $req = FCGI::Request(\*STDIN, $out , \*STDERR, \%ENV);


sub initIpc($)
{
	my $ipckey = shift;
	$share = new IPC::ShareLite( 
							-key     => $ipckey,
							-create  => 'yes',
							-destroy => 'no'
							) or die $!;
}


sub initializeFCGI
{
	my %params = @_;
	
	
	$requestCallback = $params{'requestCallback'};
	$preForkCallback = $params{'preForkCallback'} if exists $params{'preForkCallback'};
	$afterRequestCallback = $params{'afterRequestCallback'} if exists $params{'afterRequestCallback'};
	$postForkCallback = $params{'postForkCallback'} if exists $params{'postForkCallback'};
	$minSpares = $params{'minSpares'} if exists $params{'minSpares'};
	$maxSpares = $params{'maxSpares'} if exists $params{'maxSpares'};
	$maxInstances = $params{'maxInstances'} if exists $params{'maxInstances'};
	$reSpawnInterval = $params{'reSpawnInterval'} if exists $params{'reSpawnInterval'};
	$ipckey = $params{'ipcKey'} if exists $params{'ipcKey'};


	$share = initIpc($ipckey);

	$share->store(Storable::freeze({
		'config' => {
						'minSpares' => $minSpares,
						'maxSpares' => $maxSpares,
						'maxInstances' => $maxInstances,
						'lastWatermark' => time,
						'reSpawnInterval' => $reSpawnInterval,
						'ipcKey' => $ipckey
					}
	}));

	&stateLock;
	$globalState->{$$}{'state'}='idle';
	$globalState->{$$}{'atime'}=time;
	$globalState->{$$}{'role'}='master';
	&stateUnlock;

	warn(localtime(time).'FCGIMgr initialized with ipcKey: '.$ipckey)if $debug eq 'true';
	
	$0 = 'handler_'.$ipckey.' '.$role.' - idle';
	
}


sub getGlobalState
{
	return $globalState;
}


sub runFCGI
{
	
	

	while(1)
	{
#		alarm(5) if $role eq 'slave';
#		alarm(2) if $role eq 'master';


		while($req->Accept() >= 0)
		{
#			alarm(0);

			$ENV{'TIMEKEY'}=time;

			$last_request = time;

			warn(localtime(time).'FCGIMgr got req '.$$)if $debugverbose eq 'true';

			my $rolestr = $role;
			$rolestr.=' ('.$masterpid.')' if $role eq 'slave';
			$0 = 'handler_'.$ipckey.' '.$rolestr.' - serving';
			
			&stateLock;
			$globalState->{$$}{'state'}='working';
			$globalState->{$$}{'atime'}=time;
			$globalState->{$$}{'role'}=$role;
			$globalState->{$$}{'count'}++;
			$globalState->{'config'}{'globalCount'}++;
			&stateUnlock;

			my $query = new MyCGI();
									
			&processRequest($query);

			$0 = 'handler_'.$ipckey.' '.$rolestr.' - serving 1';

			$req->Flush();
			$req->Finish();

			$0 = 'handler_'.$ipckey.' '.$rolestr.' - serving 2';
	
			eval{&{$afterRequestCallback}()} if defined $afterRequestCallback;
			warn 'error in afterRequestCallback:'.$@ if $@;

			$0 = 'handler_'.$ipckey.' '.$rolestr.' - serving 3';

			if(&manageProcesses eq 'quit')
			{
				warn(localtime(time).'FCGIMgr removed worker 2 '.$$)if $debug eq 'true';
	
				&stateLock;
				delete $globalState->{$$};
				&stateUnlock;

				exit;
			}
#			alarm(5) if $role eq 'slave';
#			alarm(2) if $role eq 'master';
		}
		#warn('FCGIMgr got no request '.$$)if $debug eq 'true';
	}
}

sub runSingleFCGI
{
	$requestCallback = shift;

	while($req->Accept() >= 0)
	{
		my $query = new MyCGI();
		&processRequest($query);
		$req->Flush();
		$req->Finish();
	}
}

sub processRequest
{
	my $query = shift;

	my $output;
	open STDOUT, '>', \$output or die "Can't redirect STDOUT: $!";
	$| = 1;
	eval{&{$requestCallback}($query);};
	close STDOUT;

	if($@)
	{
		print $out "Status: 500 Internal Server Error\n";
		print $out "Content-Type: text/plain\n\nsystemfehler\n";
		warn localtime(time)."INTERNAL ERROR: $@ ::: $output";
	}else{
		my $content = $output;
		
		if (($content !~ /(?:Content-Type|Location|304 Not Modified)/)or(($content !~ /\n\n/)and($content !~ /\r\n\r\n/)))
		{
			mkdir '/tmp/reqlog' if ! -d '/tmp/reqlog';
			open outfile,'>/tmp/reqlog/'.time;
			print outfile localtime(time).'::'.$content.'::'."\n";
			foreach my $key (sort keys %ENV)
			{
				print outfile "$key $ENV{$key}\n";
			}
			foreach my $param (sort $query->param)
			{
				foreach my $value (sort $query->param($param))
				{
					print outfile "$param : $value\n";
				}
			}
			close outfile;
		
		}
		
		print $out $content;
	}
		
	
}

sub manageProcesses
{
	my $time = time;

	my $retval;
	
	&stateLock;
	$globalState->{$$}{'state'}='idle';
	$globalState->{$$}{'role'}=$role;
	$globalState->{$$}{'atime'}=$time;

	my $rolestr = $role;
	$rolestr.=' ('.$masterpid.')' if $role eq 'slave';
	$0 = 'handler_'.$ipckey.' '.$rolestr.' - idle';

	# respawn
	
	if (($reSpawnInterval != 0)and($role eq 'master')and($lastReSpawn+$reSpawnInterval < $time))
	{
		$lastReSpawn = $time;
		warn(localtime($time).'FCGIMgr activating RESPAWN procedure '.$$)if $debug eq 'true';
		$globalState->{'config'}{'last_respawn'} = scalar(localtime());

		foreach my $worker (keys %{$globalState})
		{
			next if $worker eq 'config';
			if ($globalState->{$worker}{'role'} eq 'slave')
			{
				$globalState->{$worker}{'have_to_quit'} = 'true';
			}
		}
		
	}
	my $lastWatermark = $globalState->{'config'}{'lastWatermark'};

	&stateUnlock;


	my $idlecount;

	# count idles
	foreach my $worker (keys %{$globalState})
	{
		next if $worker eq 'config';
		next if $globalState->{$worker}{'role'} eq 'master';

		if (($globalState->{$worker}{'state'} eq 'idle')and($globalState->{$worker}{'have_to_quit'} ne 'true'))
		{
			$idlecount++ 
		};

	}

	if ($globalState->{$$}{'have_to_quit'} eq 'true')
	{
		warn(localtime($time).'FCGIMgr quitting from RESPAWN '.$$)if $debug eq 'true';
		return 'quit';
	}
	
	# maybe we need a new worker
	if(($role eq 'master')and($idlecount < $minSpares)and(scalar(keys %{$globalState}) < $maxInstances ))
	{

		&{$preForkCallback};


		if (my $newpid = fork())
		{
			warn(localtime($time).'FCGIMgr created new child '.$newpid.' from '.$$) if $debug eq 'true';
			&stateLock;
			$retval = 'parent';
		}
		else
		{
			&stateLock;
			$retval = 'child';
			$role = 'slave';
			$lastWatermark = $time;
			$globalState->{'config'}{'lastWatermark'} = $lastWatermark;
			$globalState->{$$}{'role'}='slave';
			
			my $rolestr = $role;
			$rolestr.=' ('.$masterpid.')' if $role eq 'slave';
			$0 = 'handler_'.$ipckey.' '.$rolestr.' - idle';

		}
		$globalState->{$$}{'state'}='idle';
		$globalState->{$$}{'atime'}=$time;

		&stateUnlock;

		&{$postForkCallback};
	}
	# maybe we need to remove a worker
	elsif(($role eq 'slave')and($idlecount > $maxSpares))
	{
		if( ($lastWatermark + 60 ) < $time )
		{
			$retval = 'quit';
		}
	}
	elsif($role eq 'slave')
	{
		if( ($lastWatermark + 10 ) < $time )
		{
			$lastWatermark = $time;
			&stateLock;
			$globalState->{'config'}{'lastWatermark'} = $lastWatermark;
			&stateUnlock;
		}
	}
	
	return $retval;

}


sub stateLock()
{
	$share->lock(0);
	$globalState = Storable::thaw($share->fetch());
}
sub stateUnlock()
{
	$share->store(Storable::freeze($globalState));
	$share->unlock;
}

1;