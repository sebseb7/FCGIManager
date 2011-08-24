#!/usr/bin/perl

use strict;
use FCGIManager;


sub request($)
{
	my $query = shift;
	
	
	print "Content-Type:text/plain\n\n";
	print "OK\n";
	
}


&FCGIManager::runSingleFCGI(\&request);


