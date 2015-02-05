#
# Copyright 2014 Andrew Ayer
#
# This file is part of strip-nondeterminism.
#
# strip-nondeterminism is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# strip-nondeterminism is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with strip-nondeterminism.  If not, see <http://www.gnu.org/licenses/>.
#
package File::StripNondeterminism::handlers::zip;

use strict;
use warnings;

use File::Temp;
use Archive::Zip qw/:CONSTANTS :ERROR_CODES/;

# A magic number from Archive::Zip for the earliest timestamp that
# can be represented by a Zip file.  From the Archive::Zip source:
# "Note, this isn't exactly UTC 1980, it's 1980 + 12 hours and 1
# minute so that nothing timezoney can muck us up."
use constant SAFE_EPOCH => 315576060;

# Extract and return the first $nbytes of $member (an Archive::Zip::Member)
sub peek_member {
	my ($member, $nbytes) = @_;
	my $original_size = $member->compressedSize();
	my $old_compression_method = $member->desiredCompressionMethod(COMPRESSION_STORED);
	$member->rewindData() == AZ_OK or die "failed to rewind ZIP member";
	my ($buffer, $status) = $member->readChunk($nbytes);
	die "failed to read ZIP member" if $status != AZ_OK && $status != AZ_STREAM_END;
	$member->endRead();
	$member->desiredCompressionMethod($old_compression_method);
	$member->{'compressedSize'} = $original_size; # Work around https://github.com/redhotpenguin/perl-Archive-Zip/issues/11
	return $$buffer;
}

# Normalize the contents of $member (an Archive::Zip::Member) with $normalizer
sub normalize_member {
	my ($member, $normalizer) = @_;

	# Extract the member to a temporary file.
	my $tempdir = File::Temp->newdir();
	my $filename = "$tempdir/member";
	my $original_size = $member->compressedSize();
	$member->extractToFileNamed($filename);
	$member->{'compressedSize'} = $original_size; # Work around https://github.com/redhotpenguin/perl-Archive-Zip/issues/11

	# Normalize the temporary file.
	if ($normalizer->($filename)) {
		# Normalizer modified the temporary file.
		# Replace the member's contents with the temporary file's contents.
		open(my $fh, '<', $filename) or die "Unable to open $filename: $!";
		$member->contents(do { local $/; <$fh> });
	}

	unlink($filename);
}

use constant {
	CENTRAL_HEADER => 0,
	LOCAL_HEADER => 1
};
sub normalize_extra_fields {
	# See http://sources.debian.net/src/zip/3.0-6/proginfo/extrafld.txt for extra field documentation
	# $header_type is CENTRAL_HEADER or LOCAL_HEADER.
	# WARNING: some fields have a different format depending on the header type
	my ($field, $header_type) = @_;

	my $result = "";
	my $pos = 0;
	my ($id, $len);

	# field format: 2 bytes id, 2 bytes data len, n bytes data
	while (($id, $len) = unpack("vv", substr($field, $pos))) {
		if ($id == 0x5455) {
			# extended timestamp found.
			# first byte of data contains flags.
			$result .= substr($field, $pos, 5);
			# len determines how many timestamps this field contains
			# this works for both the central header and local header version
			for (my $i = 1; $i < $len; $i += 4) {
				$result .= pack("V", $File::StripNondeterminism::canonical_time // SAFE_EPOCH);
			}
		} elsif ($id == 0x7875) { # Info-ZIP New Unix Extra Field
			$result .= substr($field, $pos, 4);
			#  Version       1 byte      version of this extra field, currently 1
			#  UIDSize       1 byte      Size of UID field
			#  UID           Variable    UID for this entry
			#  GIDSize       1 byte      Size of GID field
			#  GID           Variable    GID for this entry
			# (Same format for both central header and local header)
			if (ord(substr($field, $pos + 4, 1)) == 1) {
				my $uid_len = ord(substr($field, $pos + 5, 1));
				my $gid_len = ord(substr($field, $pos + 6 + $uid_len, 1));
				$result .= pack("CCx${uid_len}Cx${gid_len}", 1, $uid_len, $gid_len);
			} else {
				$result .= substr($field, $pos + 4, $len);
			}
		} else {
			# use the current extra field unmodified.
			$result .= substr($field, $pos, $len+4);
		}
		$pos += $len + 4;
	}

	return $result;
}

sub normalize {
	my ($zip_filename, %options) = @_;
	my $filename_cmp = $options{filename_cmp} || sub { $a cmp $b };
	my $zip = Archive::Zip->new($zip_filename);
	my @filenames = sort $filename_cmp $zip->memberNames();
	for my $filename (@filenames) {
		my $member = $zip->removeMember($filename);
		$zip->addMember($member);
		$options{member_normalizer}->($member) if exists $options{member_normalizer};
		$member->setLastModFileDateTimeFromUnix($File::StripNondeterminism::canonical_time // SAFE_EPOCH);
		$member->unixFileAttributes(0644) if $member->fileAttributeFormat() == FA_UNIX;
		$member->cdExtraField(normalize_extra_fields($member->cdExtraField(), CENTRAL_HEADER));
		$member->localExtraField(normalize_extra_fields($member->localExtraField(), LOCAL_HEADER));
	}
	$zip->overwrite();
	return 1;
}

1;
