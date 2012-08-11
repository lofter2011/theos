#!/usr/bin/perl

use 5.006;
use warnings;
use strict;
use FindBin;
use lib "$FindBin::Bin/lib";
use Digest::MD5 'md5_hex';
use Module::Load;
use Module::Load::Conditional 'can_load';
use Getopt::Long;

package Logos;
sub sigil { my $id = shift; return "_logos_$id\$"; }
package main;

use Logos::Util;
$Logos::Util::errorhandler = \&utilErrorHandler;

use aliased 'Logos::Patch';
use aliased 'Logos::Patch::Source::Generator' => 'Patch::Source::Generator';
use aliased 'Logos::Patch';
use aliased 'Logos::Group';
use aliased 'Logos::Method';
use aliased 'Logos::Class';
use aliased 'Logos::Subclass';
use aliased 'Logos::StaticClassGroup' ;

use Logos::Generator;

%main::CONFIG = ( generator => "MobileSubstrate",
		  warnings => "default",
		);
$main::warnings = 0;

GetOptions("config|c=s" => \%main::CONFIG);

my $filename = $ARGV[0];
die "Syntax: $FindBin::Script filename\n" if !$filename;
open(FILE, $filename) or die "Could not open $filename.\n";

my @lines = ();
my @patches = ();
my $preprocessed = 0;

my %lineMapping = ();

{ # If the first line matches "# \d \"...\"", this file has been run through the preprocessor already.
my $firstline = <FILE>;
seek(FILE, 0, Fcntl::SEEK_SET);
if($firstline && $firstline =~ /^# \d+ \"(.*?)\"$/) {
	$preprocessed = 1;
	$filename = $1;
}
$.--; # Reset line number.
}

{
my $readignore = 0;
my $built = "";
my $building = 0;
my $iflevel = -1;
READLOOP: while(my $line = <FILE>) {
	chomp($line);

	if($preprocessed && $line =~ /^# (\d+) \"(.*?)\"/) {
		$lineMapping{$.+1} = [$2, $1];
	}

	if($readignore) {
		# Handle #if nesting.
		if($iflevel > -1 && $line =~ /^#\s*if(n?def)?/) {
			$iflevel++;
		} elsif($iflevel > 0 && $line =~ /^#\s*endif/) {
			$line = $';
			$iflevel--;
		}

		# End of a multi-line comment or #if block while ignoring input.
		if($iflevel == 0 || ($iflevel == -1 && $line =~ /^.*?\*\/\s*/)) {
			$readignore = 0;
			$iflevel = -1;
			$line = $';
		}
	}
	if($readignore) { push(@lines, ""); next; }

	my @quotes = quotes($line);

	# Delete all single-line /* xxx */ comments.
	while($line =~ /\/\*.*?\*\//g) {
		next if fallsBetween($-[0], @quotes);
		$line = $`.$';
		redo READLOOP;
	}
	
	# Start of a multi-line /* comment.
	while($line =~ /\/\*.*$/g) {
		next if fallsBetween($-[0], @quotes);
		$line = $`;
		push(@lines, $line);
		$readignore = 1;
		next READLOOP;
	}

	# Delete all single-line to-EOL // xxx comments.
	while($line =~ /\/\//g) {
		next if fallsBetween($-[0], @quotes);
		$line = $`;
		redo READLOOP;
	}

	# #if 0.
	while($line =~ /^\s*#\s*if\s+0/) {
		$iflevel = 1;
		push(@lines, "");
		$readignore = 1;
		next READLOOP;
	}

	if(!$readignore) {
		# Line starts with - (return), start gluing lines together until we find a { or ;...
		if(!$building
				&& (
					$line =~ /^\s*(%new.*?)?\s*([+-])\s*\(\s*(.*?)\s*\)/
					|| $line =~ /%orig[^;]*$/
					|| $line =~ /%init[^;]*$/
				)
				&& index($line, "{") < $-[0] && index($line, ";") < $-[0]) {
			if(fallsBetween($-[0], @quotes)) {
				push(@lines, $line);
				next;
			}
			$building = 1;
			$built = $line;
			push(@lines, "");
			next;
		} elsif($building) {
			$line =~ s/^\s+//g;
			$built .= " ".$line;
			if(index($line,"{") != -1 || index($line,";") != -1) {
				push(@lines, $built);
				$building = 0;
				$built = "";
				next;
			}
			push(@lines, "");
			next;
		}
		push(@lines, $line) if !$readignore;
	}
}
if($building == 1) {
	push(@lines, $built);
}
}

close(FILE);

$lineMapping{0} = ["$filename", 0] if scalar keys %lineMapping == 0;

my $lineno = 0;

my $defaultGroup = Group->new();
$defaultGroup->name("_ungrouped");
$defaultGroup->explicit(0);
my $staticClassGroup = StaticClassGroup->new();
my @groups = ($defaultGroup, $staticClassGroup);

my $currentGroup = $defaultGroup;
my $currentClass = undef;
my $currentMethod = undef;
my $newMethodTypeEncoding = undef;

my %classes = ();

my @nestingstack = ();

my @firstDirectivePosition;
my @lastInitPosition;

my %depthMapping = ("0:0" => 0);
my $depth = 0;

# Mk. I processing loop - directive processing.
foreach my $line (@lines) {
	# We don't want to process in-order, so %group %thing %end won't kill itself automatically
	# because it found a %end with the %group. This allows things to proceed out-of-order:
	# we re-start the scan loop with the next % every time we find a match so that the commands don't need to
	# be in the processed order on every line. That would be pointless.

	my @quotes = quotes($line);

	# Brace Depth Mapping
	pos($line) = 0;
	my %depthsForCurrentLine;
	$depthsForCurrentLine{"$lineno:0"} = $depth;
	while($line =~ /([{}]|(?<=@)(interface|implementation|end))/g) {
		next if fallsBetween($-[0], @quotes);

		my $depthtoken = $lineno.":".($-[0]+1);

		$depth++ if($& eq "{");
		$depth++ if($& eq "implementation");
		$depth++ if($& eq "interface");
		$depth-- if($& eq "}");
		$depth-- if($& eq "end");
		$depthMapping{$depthtoken} = $depth;
		$depthsForCurrentLine{$depthtoken} = $depth;
	}

	# Directive
	pos($line) = 0;
	while($line =~ m/\B(?=(\%\w|&\s*\%\w|[+-]\s*\(\s*.*?\s*\)))/gc) {
		next if fallsBetween($-[0], @quotes);

		my @directiveDepthTokens = locationOpeningDepthAtPositionInMapping(\%depthsForCurrentLine, $lineno, $-[0]);
		my $directiveDepth;
		$directiveDepth = 0 if(!@directiveDepthTokens);
		$directiveDepth = $depthsForCurrentLine{join(':', @directiveDepthTokens)} if @directiveDepthTokens;

		if($line =~ /\G%hook\s+([\$_\w]+)/gc) {
			# "%hook <identifier>"
			fileError($lineno, "%hook does not make sense inside a block") if($directiveDepth >= 1);
			nestingMustNotContain($lineno, "%hook", \@nestingstack, "hook", "subclass");

			@firstDirectivePosition = ($lineno, $-[0]) if !@firstDirectivePosition;

			nestPush("hook", $lineno, \@nestingstack);

			$currentClass = $currentGroup->addClassNamed($1);
			$classes{$currentClass->name}++;
			patchHere(undef);
		} elsif($line =~ /\G%subclass\s+([\$_\w]+)\s*:\s*([\$_\w]+)\s*(\<\s*(.*?)\s*\>)?/gc) {
			# %subclass <identifier> : <identifier> \<<protocols ...>\>
			fileError($lineno, "%subclass does not make sense inside a block") if($directiveDepth >= 1);
			nestingMustNotContain($lineno, "%subclass", \@nestingstack, "hook", "subclass");

			@firstDirectivePosition = ($lineno, $-[0]) if !@firstDirectivePosition;

			nestPush("subclass", $lineno, \@nestingstack);

			my $classname = $1;
			my $superclassname = $2;
			$currentClass = Subclass->new();
			$currentClass->name($classname);
			$currentClass->superclass($superclassname);
			if(defined($3) && defined($4)) {
				my @protocols = split(/\s*,\s*/, $4);
				foreach(@protocols) {
					$currentClass->addProtocol($_);
				}
			}
			$currentGroup->addClass($currentClass);

			$staticClassGroup->addDeclaredOnlyClass($classname);
			$classes{$superclassname}++;
			$classes{$classname}++;

			patchHere(undef);
		} elsif($line =~ /\G%group\s+([\$_\w]+)/gc) {
			# %group <identifier>
			fileError($lineno, "%group does not make sense inside a block") if($directiveDepth >= 1);
			nestingMustNotContain($lineno, "%group", \@nestingstack, "group");

			@firstDirectivePosition = ($lineno, $-[0]) if !@firstDirectivePosition;

			nestPush("group", $lineno, \@nestingstack);

			$currentGroup = getGroup($1);
			my $existed = 0;
			if(!defined($currentGroup)) {
				$currentGroup = Group->new();
				$currentGroup->name($1);
				push(@groups, $currentGroup);
			} else {
				$existed = 1;
			}

			my $capturedGroup = $currentGroup;
			if(!$existed) {
				patchHere(Patch::Source::Generator->new($capturedGroup, 'declarations'));
			} else {
				patchHere(undef);
			}
		} elsif($line =~ /\G%class\s+([+-])?([\$_\w]+)/gc) {
			# %class [+-]<identifier>
			@firstDirectivePosition = ($lineno, $-[0]) if !@firstDirectivePosition;

			my $scope = $1;
			$scope = "-" if !$scope;
			my $classname = $2;
			if($scope eq "+") {
				$staticClassGroup->addUsedMetaClass($classname);
			} else {
				$staticClassGroup->addUsedClass($classname);
			}
			$classes{$classname}++;
			patchHere(undef);
		} elsif($line =~ /\G%c\(\s*([+-])?([\$_\w]+)\s*\)/gc) {
			# %c([+-]<identifier>)
			@firstDirectivePosition = ($lineno, $-[0]) if !@firstDirectivePosition;

			my $scope = $1;
			$scope = "-" if !$scope;
			my $classname = $2;
			if($scope eq "+") {
				$staticClassGroup->addUsedMetaClass($classname);
			} else {
				$staticClassGroup->addUsedClass($classname);
			}
			$classes{$classname}++;
			patchHere(Patch::Source::Generator->new($classname, 'classReferenceWithScope', $scope));
		} elsif($line =~ /\G%new(\((.*?)\))?(?=\W?)/gc) {
			# %new[(type)]
			nestingMustContain($lineno, "%new", \@nestingstack, "hook", "subclass");
			my $xtype = "";
			$xtype = $2 if $2;
			$newMethodTypeEncoding = $xtype;
			patchHere(undef);
		} elsif($currentClass && $line =~ /\G([+-])\s*\(\s*(.*?)\s*\)(?=\s*[\w:])/gc && $directiveDepth < 1) {
			# [+-] (<return>)<[X:]>, but only when we're in a %hook.

			# Gasp! We've been moved to a different group!
			if($currentClass->group != $currentGroup) {
				my $classname = $currentClass->name;
				$currentClass = $currentGroup->addClassNamed($classname);
			}

			my $scope = $1;
			my $return = $2;

			my $method = Method->new();

			$method->class($currentClass);
			if($scope eq "+") {
				$currentClass->hasmetahooks(1);
			} else {
				$currentClass->hasinstancehooks(1);
			}

			$method->scope($scope);
			$method->return($return);

			if(defined $newMethodTypeEncoding) {
				$method->setNew(1);
				$method->type($newMethodTypeEncoding);
				$newMethodTypeEncoding = undef;
			}

			my @selparts = ();

			my $patchStart = $-[0];

			# word, then an optional: ": (argtype)argname"
			while($line =~ /\G\s*([\$\w]*)(\s*:\s*(\((.+?)\))?\s*([\$\w]+?)\b)?/gc) {
				if(!$1 && !$2) { # Exit the loop if both Keywords and Args are missing: e.g. false positive.
					pos($line) = $-[0];
					last;
				}

				my $keyword = $1; # Add any keyword.
				push(@selparts, $keyword);

				last if !$2;  # Exit the loop if there are no args (single keyword.)
				$method->addArgument($3 ? $4 : "id", $5);
			}

			$method->selectorParts(@selparts);
			$currentClass->addMethod($method);
			$currentMethod = $method;

			my $patch = Patch->new();
			$patch->line($lineno);
			$patch->range($patchStart, pos($line));
			$patch->source(Patch::Source::Generator->new($method, 'definition'));
			addPatch($patch);
		} elsif($line =~ /\G%orig\b/gc) {
			# %orig, with optional following parens.
			nestingMustContain($lineno, "%orig", \@nestingstack, "hook", "subclass");
			fileWarning($lineno, "%orig in a new method will be non-operative.") if $currentMethod->isNew;

			my $patchStart = $-[0];

			my $remaining = substr($line, pos($line));
			my $orig_args = undef;

			my ($popen, $pclose) = matchedParenthesisSet($remaining);
			if(defined $popen) {
				$orig_args = substr($remaining, $popen, $pclose-$popen-1);;
				pos($line) = pos($line) + $pclose;
			}

			my $capturedMethod = $currentMethod;
			my $patch = Patch->new();
			$patch->line($lineno);
			$patch->range($patchStart, pos($line));
			$patch->source(Patch::Source::Generator->new($capturedMethod, 'originalCall', $orig_args));
			addPatch($patch);
		} elsif($line =~ /\G&\s*%orig\b/gc) {
			# &%orig, at a word boundary
			nestingMustContain($lineno, "%orig", \@nestingstack, "hook", "subclass");
			fileError($lineno, "no original method pointer for &%orig in new method.") if $currentMethod->isNew;

			my $capturedMethod = $currentMethod;
			patchHere(Patch::Source::Generator->new($capturedMethod, 'originalFunctionName'));
		} elsif($line =~ /\G%log\b/gc) {
			# %log
			nestingMustContain($lineno, "%log", \@nestingstack, "hook", "subclass");

			my $capturedMethod = $currentMethod;
			patchHere(Patch::Source::Generator->new($capturedMethod, 'buildLogCall'));
		} elsif($line =~ /\G%ctor\b/gc) {
			# %ctor
			fileError($lineno, "%ctor does not make sense inside a block") if($directiveDepth >= 1);
			nestingMustNotContain($lineno, "%ctor", \@nestingstack, "hook", "subclass");
			my $replacement = "static __attribute__((constructor)) void _logosLocalCtor_".substr(md5_hex($`.$lineno.$'), 0, 8)."()";
			patchHere($replacement);
		} elsif($line =~ /\G%init\b/gc) {
			# %init, with optional following parens
			fileError($lineno, "%init does not make sense outside a block") if($directiveDepth < 1);
			my $groupname = "_ungrouped";

			my $patchStart = $-[0];

			my $remaining = substr($line, pos($line));
			my $argstring = undef;
			my ($popen, $pclose) = matchedParenthesisSet($remaining);
			if(defined $popen) {
				$argstring = substr($remaining, $popen, $pclose-$popen-1);;
				pos($line) = pos($line) + $pclose;
			}

			my @args;
			@args = smartSplit(qr/\s*,\s*/, $argstring) if defined($argstring);

			my $tempgroupname = undef;
			$tempgroupname = $args[0] if $args[0] && $args[0] !~ /=/;
			if(defined($tempgroupname)) {
				$groupname = $tempgroupname;
				shift(@args);
			}

			my $group = getGroup($groupname);

			foreach my $arg (@args) {
				if($arg !~ /=/) {
					fileWarning($lineno, "unknown argument to %init: $arg");
					next;
				}

				my @parts = smartSplit(qr/\s*=\s*/, $arg, 2);
				if(!defined($parts[0]) || !defined($parts[1])) {
					fileWarning($lineno, "invalid class=expr in %init");
					next;
				}

				my $classname = $parts[0];
				my $expr = $parts[1];
				my $scope = "-";
				if($classname =~ /^([+-])/) {
					$scope = $1;
					$classname = $';
				}

				my $class = $group->getClassNamed($classname);
				if(!defined($class)) {
					fileWarning($lineno, "tried to set expression for unknown class $classname in group $groupname");
					next;
				}

				$class->expression($expr) if $scope eq "-";
				$class->metaexpression($expr) if $scope eq "+";
			}

			fileError($lineno, "%init for an undefined %group $groupname") if !$group;
			fileError($lineno, "re-%init of %group ".$group->name.", first initialized at ".lineDescriptionForPhysicalLine($group->initLine)) if $group->initialized;

			$group->initLine($lineno);
			$group->initialized(1);

			if($groupname eq "_ungrouped") {
				$staticClassGroup->initLine($lineno);
				$staticClassGroup->initialized(1);
			}

			while($line =~ /\G\s*;/gc) { };
			my $patchEnd = pos($line);

			my $patch = Patch->new();
			$patch->line($lineno);
			$patch->range($patchStart, pos($line));
			if($groupname eq "_ungrouped") {
				$patch->source(["{",
						Patch::Source::Generator->new($group, 'initializers'),
						Patch::Source::Generator->new($staticClassGroup, 'initializers'),
						"}"]);
			} else {
				$patch->source(Patch::Source::Generator->new($group, 'initializers'));
			}
			addPatch($patch);

			@lastInitPosition = ($lineno, pos($line));
		} elsif($line =~ /\G%end\b/gc) {
			# %end
			fileError($lineno, "%end does not make sense inside a block") if($directiveDepth >= 1);
			my $closing = nestPop(\@nestingstack);
			fileError($lineno, "dangling %end") if !$closing;
			if($closing eq "group") {
				$currentGroup = getGroup("_ungrouped");
			}
			if($closing eq "hook" || $closing eq "subclass") {
				$currentClass = undef;
			}
			patchHere(undef);
		} elsif($line =~ /\G%config\s*\(\s*(\w+)\s*=\s*(.*?)\s*\)/gc) {
			$main::CONFIG{$1} = $2;
			patchHere(undef);
		}
	}

	$lineno++;
}

while(scalar(@nestingstack) > 0) {
	my $closing = pop(@nestingstack);
	my @parts = split(/:/, $closing);
	fileWarning($lineno, "missing %end (%".$parts[0]." opened at ".lineDescriptionForPhysicalLine($parts[1])." extends to EOF)");
}

Logos::Generator::use($main::CONFIG{"generator"});

my $hasGeneratorPreamble = $preprocessed; # If we're already preprocessed, we cannot insert #include statements.
$hasGeneratorPreamble = Logos::Generator::for->findPreamble(\@lines) if !$hasGeneratorPreamble;

if(@firstDirectivePosition) {
	# Loop until we find a blank line at depth 0 to splice our preamble in.
	# The top of the file (or, alternatively, the first line of our file post-
	# preprocessing) will be considered to be a blank line.
	#
	# This breaks if one includes a blank line between "int blah()" and its
	# corresponding "{", however. Nobody codes like that anyway.
	# This will probably also break if you keep your "{" and "}" inside header files
	# that you #include into your code. Nobody codes like that, either.

	# Optimization: Only do this once.
	my @depthKeys = sort {
		my @ba=split(/:/,$b);
		my @aa=split(/:/,$a);
		($ba[0] == $aa[0]
		? $ba[1] <=> $aa[1]
			: $ba[0] <=> $aa[0])
	} keys %depthMapping;
	my $line = $firstDirectivePosition[0];
	my $pos = $firstDirectivePosition[1];
	while(1) {
		my $depth = lookupDepthMapping($line, $pos, \@depthKeys);
		my $above;
		$above = "" if $line eq 0;
		if($preprocessed) {
			my @lm = lookupLineMapping($line);
			$above = "" if($lm[0] eq $filename && $lm[1] == 1);
		}
		$above = $lines[$line-1] if !defined $above;

		last if $depth == 0 && $above =~ /^\s*$/;

		$line-- if($pos == 0);
		$pos = 0;
	}
	my $patch = Patch->new();
	$patch->line($line);
	my @patchsource = ();
	push(@patchsource, Patch::Source::Generator->new(undef, 'preamble')) if !$hasGeneratorPreamble;
	push(@patchsource, Patch::Source::Generator->new(undef, 'generateClassList', keys %classes));
	push(@patchsource, Patch::Source::Generator->new($groups[0], 'declarations'));
	push(@patchsource, Patch::Source::Generator->new($staticClassGroup, 'declarations'));
	$patch->source(\@patchsource);
	addPatch($patch);

	if(@lastInitPosition) {
		# If the static class list hasn't been initialized, glue it after the last %init directive.
		if(!$staticClassGroup->initialized) {
			my $patch = Patch->new();
			$patch->line($lastInitPosition[0]);
			$patch->range($lastInitPosition[1], $lastInitPosition[1]);
			$patch->source(Patch::Source::Generator->new($staticClassGroup, 'initializers'));
			$staticClassGroup->initialized(1);
			addPatch($patch);
		}
	} else {
		my $patch = Patch->new();
		$patch->line(scalar @lines);
		$patch->squash(1);
		$patch->source(defaultConstructorSource());
		addPatch($patch);
	}

}

my @unInitGroups = ();
foreach(@groups) {
	push(@unInitGroups, $_->name) if !$_->initialized && $_->explicit;
}
my $numUnGroups = @unInitGroups;
fileError($lineno, "non-initialized hook group".($numUnGroups == 1 ? "" : "s").": ".join(", ", @unInitGroups)) if $numUnGroups > 0;

my @sortedPatches = sort { ($b->line == $a->line ? ($b->start || -1) <=> ($a->start || -1) : $b->line <=> $a->line) } @patches;

if(exists $main::CONFIG{"dump"}) {
	my $dumphref = {
			linemap=>\%lineMapping,
			depthmap=>\%depthMapping,
			groups=>\@groups,
			patches=>\@patches,
			lines=>\@lines,
			config=>\%::CONFIG
		       };
	if($main::CONFIG{"dump"} eq "yaml") {
		load 'YAML::Syck';
		print STDERR YAML::Syck::Dump($dumphref);
	} elsif($main::CONFIG{"dump"} eq "perl") {
		load 'Data::Dumper';
		$Data::Dumper::Purity = 1;

		my @k; my @v;
		map {push(@k,$_); push(@v, $dumphref->{$_});} keys %$dumphref;
		print STDERR Data::Dumper->Dump(\@v, \@k);
	}
	#print STDERR Data::Dumper->Dump([\@groups, \@patches, \@lines, \%::CONFIG], [qw(groups patches lines config)]);
}

if($main::warnings > 0 && exists $main::CONFIG{"warnings"} && $main::CONFIG{"warnings"} eq "error") {
	exit(1);
}

for(@sortedPatches) {
	$_->apply(\@lines);
}

splice(@lines, 0, 0, generateLineDirectiveForPhysicalLine(0)) if !$preprocessed;
foreach my $oline (@lines) {
	print $oline."\n" if defined($oline);
}

sub defaultConstructorSource {
	my @return;
	my $explicitGroups = 0;
	foreach(@groups) {
		$explicitGroups++ if $_->explicit;
	}
	fileError($lineno, "Cannot generate an autoconstructor with multiple %groups. Please explicitly create a constructor.") if $explicitGroups > 0;
	push(@return, "static __attribute__((constructor)) void _logosLocalInit() {\n");
	foreach(@groups) {
		next if $_->explicit;
		fileError($lineno, "re-%init of %group ".$_->name.", first initialized at ".lineDescriptionForPhysicalLine($_->initLine)) if $_->initialized;
		push(@return, Patch::Source::Generator->new($_, 'initializers'));
		push(@return, " ");
		$_->initLine($lineno);
	}
	push(@return, "}\n");
	return \@return;
}

sub fileWarning {
	my $curline = shift;
	my $reason = shift;
	my @lineMap = lookupLineMapping($curline);
	my $filename = $lineMap[0];
	my $print = 1;
	if(exists($main::CONFIG{"warnings"})) {
		if($main::CONFIG{"warnings"} eq "error") {
			if($main::warnings == 0) {
				print STDERR "logos: warnings being treated as errors\n";
			}
		} elsif($main::CONFIG{"warnings"} eq "none") {
			$print = 0;
		}
	}
	print STDERR "$filename:".($curline > -1 ? $lineMap[1].":" : "")." warning: $reason\n" if($print == 1);
	$main::warnings++;
}

sub fileError {
	my $curline = shift;
	my $reason = shift;
	my @lineMap = lookupLineMapping($curline);
	my $filename = $lineMap[0];
	die "$filename:".($curline > -1 ? $lineMap[1].":" : "")." error: $reason\n";
}

sub nestingError {
	my $curline = shift;
	my $thisblock = shift;
	my $reason = shift;
	my @parts = split(/:/, $reason);
	fileError $curline, "$thisblock inside a %".$parts[0].", opened at ".lineDescriptionForPhysicalLine($parts[1]);
}

sub nestingMustContain {
	my $lineno = shift;
	my $trying = shift;
	my $stackref = shift;
	return if nestingContains($stackref, @_);
	fileError($lineno, "$trying found outside of ".join(" or ", @_));
}

sub nestingMustNotContain {
	my $lineno = shift;
	my $trying = shift;
	my $stackref = shift;
	nestingError($lineno, $trying, $_) if nestingContains($stackref, @_);
}

sub nestingContains {
	my $stackref = shift;
	my @stack = @$stackref;
	my @search = @_;
	my @parts = ();
	foreach my $nest (@stack) {
		@parts = split(/:/, $nest);
		foreach my $find (@search) {
			if($find eq $parts[0]) {
				$_ = $nest;
				return $_;
			}
		}
	}
	$_ = undef;
	return undef;
}

sub nestPush {
	my $type = shift;
	my $line = shift;
	my $ref_stack = shift;
	push(@{$ref_stack}, $type.":".$line);
}

sub nestPop {
	my $ref_stack = shift;
	my $outgoing = pop(@{$ref_stack});
	return undef if !$outgoing;
	my @parts = split(/:/, $outgoing);
	return $parts[0];
}

sub getGroup {
	my $name = shift;
	foreach(@groups) {
		return $_ if $_->name eq $name;
	}
	return undef;
}

sub lookupLineMapping {
	my $fileline = shift;
	$fileline++;
	for (sort {$b <=> $a} keys %lineMapping) {
		if($fileline >= $_) {
			my @x = @{$lineMapping{$_}};
			return ($x[0], $x[1] + ($fileline-$_));
		}
	}
	return undef;
}

sub generateLineDirectiveForPhysicalLine {
	my $physline = shift;
	my @lineMap = lookupLineMapping($physline);
	my $filename = $lineMap[0];
	my $lineno = $lineMap[1];
	return ($preprocessed ? "# " : "#line ").$lineno." \"$filename\"";
}

sub lineDescriptionForPhysicalLine {
	my $physline = shift;
	my @lineMap = lookupLineMapping($physline);
	my $filename = $lineMap[0];
	my $lineno = $lineMap[1];
	return "$filename:$lineno";
}

sub locationOpeningDepthAtPositionInMapping {
	my $dref = shift;
	my $fileline = shift;
	my $pos = shift;
	my $kref = shift;
	my @keys;
	if($kref) {
		@keys = @$kref;
	} else {
		@keys = sort {
			my @ba=split(/:/,$b);
			my @aa=split(/:/,$a);
			($ba[0] == $aa[0]
			? $ba[1] <=> $aa[1]
				: $ba[0] <=> $aa[0])
		} keys %$dref;
	}
	for (@keys) {
		my @depthTokens = split(/:/, $_);
		if($fileline > $depthTokens[0] || ($fileline == $depthTokens[0] && $pos >= $depthTokens[1])) {
			return @depthTokens;
		}
	}
	return undef;
}

sub lookupDepthMapping {
	my $fileline = shift;
	my $pos = shift;
	my $kref = shift;
	my @depthTokens = locationOpeningDepthAtPositionInMapping(\%depthMapping, $fileline, $pos, $kref);
	return 0 if(!@depthTokens);
	return $depthMapping{join(':', @depthTokens)};
}

sub patchHere {
	my $source = shift;
	my $patch = Patch->new();
	$patch->line($lineno);
	$patch->range($-[0], $+[0]);
	$patch->source($source);
	push @patches, $patch;
}

sub addPatch {
	my $patch = shift;
	push @patches, $patch;
}

sub utilErrorHandler {
	fileError($lineno, shift);
}
