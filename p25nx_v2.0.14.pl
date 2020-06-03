#!/usr/bin/perl
#
#
# Strict and warnings recommended.
use strict;
use warnings;
use IO::Select;
use Switch;
use Config::IniFiles;
use Digest::CRC; # For HDLC CRC.
use Device::SerialPort;
use IO::Socket;
use IO::Socket::INET;
use IO::Socket::Timeout;
use IO::Socket::Multicast;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno qw(ETIMEDOUT EWOULDBLOCK);
use Class::Struct;
use Time::HiRes qw(nanosleep);
use Term::ReadKey;
#use RPi::Pin;
#use RPi::Const qw(:all);


my $MaxLen =1024; # Max Socket Buffer length.
my $StartTime = time();


# About Message.
print "\n##################################################################\n";
print "	*** P25NX v2.0.14 ***\n";
print "	Released: May 27, 2020. Created October 17, 2019.\n";
print "	Created by:\n";
print "	Juan Carlos Pérez De Castro (Wodie) KM4NNO / XE1F\n";
print "	Bryan Fields W9CR.\n";
print "	www.wodielite.com\n";
print "	wodielite at mac.com\n\n";
print "##################################################################\n\n";

# Load Settings ini file.
print "Loading Settings...\n";
my $cfg = Config::IniFiles->new( -file => "config.ini");
# Settings:
my $Mode = $cfg->val('Settings', 'Mode'); #0 = v.24, no other modes coded at the momment.
my $HotKeys = $cfg->val('Settings', 'HotKeys');
my $LocalHost = $cfg->val('Settings', 'LocalHost');
	#my($LocalIPAddr) = inet_ntoa((gethostbyname(hostname))[4]); 
	my($LocalHostIP) = inet_ntoa((gethostbyname($LocalHost))[4]); 
my $PriorityTG = $cfg->val('Settings', 'PriorityTG');
my $MuteTGTimeout = $cfg->val('Settings', 'MuteTGTimeout');
my $UseVoicePrompts = $cfg->val('Settings', 'UseVoicePrompts');
my $UseLocalCourtesyTone = $cfg->val('Settings', 'UseLocalCourtesyTone');
my $UseRemoteCourtesyTone = $cfg->val('Settings', 'UseRemoteCourtesyTone');
my $Verbose = $cfg->val('Settings', 'Verbose');
print "  Mode = $Mode\n";
print "  HotKeys = $HotKeys\n";
print "  LocalHost = $LocalHost    ntoa($LocalHostIP)\n";
print "  Mute Talk Group Timeout = $MuteTGTimeout seconds.\n";
print "  Use Voice Prompts = $UseVoicePrompts\n";
print "  Use Local Courtesy Tone = $UseLocalCourtesyTone\n";
print "  Use Remote Courtesy Tone = $UseRemoteCourtesyTone\n";
print "  Verbose = $Verbose\n";
print "----------------------------------------------------------------------\n";



# TalkGroups:
print "Loading TalkGroups...\n";
my $TalkGroupsFile = $cfg->val('TalkGroups', 'File');
my $TG_Verbose = $cfg->val('TalkGroups', 'Verbose');
print "  Verbose = $TG_Verbose\n";
print "  Talk Groups File: " . $TalkGroupsFile ."\n";

my %TG;
my $fh;
print "  Loading TalkGroupsFile...\n";
if (!open($fh, "<", $TalkGroupsFile)) {
	print "  *** Error ***   File not found.\n";
} else {
	print "  File Ok.\n";
	my %result;
	while (my $Line = <$fh>) {
		chomp $Line;
		## skip comments and blank lines and optional repeat of title line
		next if $Line =~ /^\#/ || $Line =~ /^\s*$/ || $Line =~ /^\+/;
		#split each line into array
		my @Line = split(/\s+/, $Line);
		$TG{$Line[0]}{'RF_TalkGroup'} = $Line[0];
		$TG{$Line[0]}{'P25NX_TalkGroup'} = $Line[1];
		$TG{$Line[0]}{'MMDVM_TalkGroup'} = $Line[2];
		$TG{$Line[0]}{'MMDVM_URL'} = $Line[3];
		$TG{$Line[0]}{'MMDVM_Port'} = $Line[4];
		$TG{$Line[0]}{'Scan'} = $Line[5];
		$TG{$Line[0]}{'Linked'} = 0;
		$TG{$Line[0]}{'MMDVM_Connected'} = 0;
		$TG{$Line[0]}{'P25NX_Connected'} = 0;
		$TG{$Line[0]}{'P25Link_Connected'} = 0;
		if ($TG_Verbose) {
			print "  RF TG " . $TG{$Line[0]}{'RF_TalkGroup'};
			print ", PNX " . $TG{$Line[0]}{'P25NX_TalkGroup'};
			print ", MMDVM " . $TG{$Line[0]}{'MMDVM_TalkGroup'};
			print ", URL " . $TG{$Line[0]}{'MMDVM_URL'};
			print ", Port " . $TG{$Line[0]}{'MMDVM_Port'};
			print ", Scan " . $TG{$Line[0]}{'Scan'} . "\n";
		}
	}
	close $fh;
	if ($TG_Verbose > 2) {
		foreach my $key (keys %TG)
		{
			print "  Key field: $key\n";
			foreach my $key2 (keys %{$TG{$key}})
			{
				print "  - $key2 = $TG{$key}{$key2}\n";
			}
		}
	}
}
my $NumberOfTalkGroups = scalar keys %TG;
print "\n  Total number of links is: " . $NumberOfTalkGroups . "\n";
print "----------------------------------------------------------------------\n";



# Init MMDVM.
print "Init MMDVM.\n";
my $MMDVM_Enabled = $cfg->val('MMDVM', 'Enabled');
my $Callsign = $cfg->val('MMDVM', 'Callsign');
my $RadioID = $cfg->val('MMDVM', 'RadioID');
my $MMDVM_Verbose = $cfg->val('MMDVM', 'Verbose');
print "  Enabled = $MMDVM_Enabled\n";
print "  Callsign = $Callsign\n";
print "  RadioID = $RadioID\n";
print "  Verbose = $MMDVM_Verbose\n";

#my %MMDVM;
my $MMDVM_LocalHost = $LocalHost; # Bind Address.
my $MMDVM_LocalPort = 41020; # Local Port.
my $MMDVM_RemoteHost; # Buffer for Rx data IP.
my $MMDVM_Poll_Timer_Interval = 5; # sec.
my $MMDVM_Poll_NextTimer = time() + $MMDVM_Poll_Timer_Interval;
print "----------------------------------------------------------------------\n";



# Init P25Link.
print "Init P25Link.\n";
my $P25Link_Enabled = $cfg->val('P25Link', 'Enabled');
my $P25Link_Verbose =$cfg->val('P25Link', 'Verbose');
print "  Enabled = $P25Link_Enabled\n";
print "  Verbose = $P25Link_Verbose\n";
print "----------------------------------------------------------------------\n";



# Init P25NX.
print "Init P25NX.\n";
my $P25NX_Enabled = $cfg->val('P25NX', 'Enabled');
my $P25NX_Verbose =$cfg->val('P25NX', 'Verbose');
print "  Enabled = $P25NX_Enabled\n";
print "  Verbose = $P25NX_Verbose\n";

my $P25NX_Port = 30000;
print "----------------------------------------------------------------------\n";



# Quantar HDLC Init.
print "Init HDLC.\n";
my $HDLC_RTRT_Enabled = $cfg->val('HDLC', 'RTRT_Enabled');
my $HDLC_Verbose =$cfg->val('HDLC', 'Verbose');
print "  RT/RT ENabled = $HDLC_RTRT_Enabled\n";
print "  Verbose = $HDLC_Verbose\n";

my %Quant;
foreach (my $i = 0; $i < 1; $i++ ) {
	$Quant{$i}{'FrameType'} = 0;
	$Quant{$i}{'LocalRx'} = 0;
	$Quant{$i}{'LocalRx_Time'} = 0;
	$Quant{$i}{'IsDigitalVoice'} = 0;
	$Quant{$i}{'IsPage'} = 0;
	$Quant{$i}{'dBm'} = 0;
	$Quant{$i}{'RSSI'} = 0;
	$Quant{$i}{'RSSI_Is_Valid'} = 0;
	$Quant{$i}{'InvertedSignal'} = 0;
	$Quant{$i}{'CandidateAdjustedMM'} = 0;
	$Quant{$i}{'BER'} = 0;
	$Quant{$i}{'SourceDev'} = 0;
	$Quant{$i}{'Encrypted'} = 0;
	$Quant{$i}{'Explicit'} = 0;
	$Quant{$i}{'IndividualCall'} = 0;
	$Quant{$i}{'ManufacturerID'} = 0;
	$Quant{$i}{'Emergency'} = 0;
	$Quant{$i}{'Protected'} = 0;
	$Quant{$i}{'FullDuplex'} = 0;
	$Quant{$i}{'PacketMode'} = 0;
	$Quant{$i}{'Priority'} = 0;
	$Quant{$i}{'IsTGData'} = 0;
	$Quant{$i}{'AstroTalkGroup'} = 0;
	$Quant{$i}{'DestinationRadioID'} = 0;
	$Quant{$i}{'SourceRadioID'} = 0;
	$Quant{$i}{'LSD'} = [0, 0, 0, 0];
	$Quant{$i}{'LSD0'} = 0;
	$Quant{$i}{'LSD1'} = 0;
	$Quant{$i}{'LSD2'} = 0;
	$Quant{$i}{'LSD3'} = 0;
	$Quant{$i}{'EncryptionI'} = 0;
	$Quant{$i}{'EncryptionII'} = 0;
	$Quant{$i}{'EncryptionIII'} = 0;
	$Quant{$i}{'EncryptionIV'} = 0;
	$Quant{$i}{'Algorythm'} = 0;
	$Quant{$i}{'KeyID'} = 0;
	$Quant{$i}{'Speech'} = "";
	$Quant{$i}{'Raw0x62'} = "";
	$Quant{$i}{'Raw0x63'} = "";
	$Quant{$i}{'Raw0x64'} = "";
	$Quant{$i}{'Raw0x65'} = "";
	$Quant{$i}{'Raw0x66'} = "";
	$Quant{$i}{'Raw0x67'} = "";
	$Quant{$i}{'Raw0x68'} = "";
	$Quant{$i}{'Raw0x69'} = "";
	$Quant{$i}{'Raw0x6A'} = "";
	$Quant{$i}{'Raw0x6B'} = "";
	$Quant{$i}{'Raw0x6C'} = "";
	$Quant{$i}{'Raw0x6D'} = "";
	$Quant{$i}{'Raw0x6E'} = "";
	$Quant{$i}{'Raw0x6F'} = "";
	$Quant{$i}{'Raw0x70'} = "";
	$Quant{$i}{'Raw0x71'} = "";
	$Quant{$i}{'Raw0x72'} = "";
	$Quant{$i}{'Raw0x73'} = "";
	$Quant{$i}{'SuperFrame'} = "";
}
#
# ICW (Infrastructure Control Word).
# Byte 1 address.
# Bte 2 frame type.
my $C_RR = 0x41;
my $C_UI = 0x03;
my $C_SABM = 0x3F;
my $C_XID = 0xBF;
# Byte 3.
# Byte 4.
# Byte 5 RT mode flag.
my $C_RTRT_Enabled = 0x02;
my $C_RTRT_Disabled = 0x04;
my $C_RTRT_DCRMode = 0x05;
# Byte 6 Op Code Start/Stop flag.
my $C_ChangeChannel = 0x06;
my $C_StartTx = 0x0C;
my $C_EndTx = 0x25;
# Byte 7 OpArg, type flag.
my $C_AVoice = 0x00;
my $C_TMS_Data_Payload = 0x06;
my $C_DVoice = 0x0B;
my $C_TMS_Data = 0x0C;
my $C_From_Comparator_Start = 0x0D;
my $C_From_Comparator_Stop = 0x0E;
my $C_Page = 0x0F;
# Byte 8 ICW flag.
my $C_DIU3000 = 0x00;
my $C_Quantar = 0xC2;
my $C_QuantarAlt = 0x1B;
# Byte 9 LDU1 RSSI.
# Byte 10 1A flag.
my $C_RSSI_Is_Valid = 0x1A;
# Byte 11 LDU1 RSSI.
#
# Byte 13 Page.
my $C_Normal_Page = 0x9F;
my $C_Emergency_Page = 0xA7;
#
my $C_AllCallTG = 0xFFFF;
#
#
my $IsTGData = 0;
my $C_Implicit_MFID = 0;
my $C_Explicit_MFID = 1;
my $Is_TG_Data = 0;
my $SuperframeCounter = 0;
#
#
my $RR_NextTimer = 0;
my $RR_Timeout = 0;
my $RR_TimerInterval = 5; # Seconds.
my $HDLC_Handshake = 0;
my $SABM_Counter = 0;
my $Message = "";
my $HDLC_Buffer = "";
my $RR_Timer = 0;
#
my $Tx_Started = 0;
my $SuperFrameCounter = 0;
my $HDLC_TxTraffic = 0;
my $LocalRx_Time;
print "----------------------------------------------------------------------\n";



# Init Serial Port for HDLC.
print "Init Serial Port.\n";
my $SerialPort;
my $SerialPort_Configuration = "SerialConfig.cnf";
if ($Mode == 0) {
	# For Linux:
	$SerialPort = Device::SerialPort->new('/dev/ttyUSB0') || die "Cannot Init Serial Port : $!\n";
	# For Mac:
	#my $SerialPort = Device::SerialPort->new('/dev/tty.usbserial') || die "Cannot Init Serial Port : $!\n";
	$SerialPort->baudrate(19200);
	$SerialPort->databits(8);
	$SerialPort->parity('none');
	$SerialPort->stopbits(1);
	$SerialPort->handshake('none');
	$SerialPort->buffers(4096, 4096);
	$SerialPort->datatype('raw');
	$SerialPort->debug(1);
	#$SerialPort->write_settings || undef $SerialPort;
	#$SerialPort->save($SerialPort_Configuration);
	#$TickCount = sprintf("%d", $SerialPort->get_tick_count());
	#$FutureTickCount = $TickCount + 5000;
	#print "  TickCount = $TickCount\n\n";
	print "To use Raspberry Pi UART you need to disable Bluetooth by editing: /boot/config.txt\n" .
	 	"Add line: dtoverlay=pi3-disable-bt-overlay\n";
}
print "----------------------------------------------------------------------\n";



# Voice Announce.
print "Loading voice announcements...\n";
my $SpeechFile = Config::IniFiles->new( -file => "Speech.ini");
print "  File = $SpeechFile\n";

my @Speech_SystemStart = $SpeechFile->val('speech_SystemStart', 'byte');
my @Speech_DefaultRevert = $SpeechFile->val('speech_DefaultRevert', 'byte');
my @HDLC_TestPattern = $SpeechFile->val('HDLC_TestPattern', 'byte');
my @Speech_WW = $SpeechFile->val('speech_WW', 'byte');
my @Speech_WWTac1 = $SpeechFile->val('speech_WWTac1', 'byte');
my @Speech_WWTac2 = $SpeechFile->val('speech_WWTac2', 'byte');
my @Speech_WWTac3 = $SpeechFile->val('speech_WWTac3', 'byte');
my @Speech_NA = $SpeechFile->val('speech_NA', 'byte');
my @Speech_NATac1 = $SpeechFile->val('speech_NATac1', 'byte');
my @Speech_NATac2 = $SpeechFile->val('speech_NATac2', 'byte');
my @Speech_NATac3 = $SpeechFile->val('speech_NATac3', 'byte');
my @Speech_Europe = $SpeechFile->val('speech_Europe', 'byte');
my @Speech_EuTac1 = $SpeechFile->val('speech_EuTac1', 'byte');
my @Speech_EuTac2 = $SpeechFile->val('speech_EuTac2', 'byte');
my @Speech_EuTac3 = $SpeechFile->val('speech_EuTac3', 'byte');
my @Speech_France = $SpeechFile->val('speech_France', 'byte');
my @Speech_Germany = $SpeechFile->val('speech_Germany', 'byte');
my @Speech_Pacific = $SpeechFile->val('speech_Pacific', 'byte');
my @Speech_PacTac1 = $SpeechFile->val('speech_PacTac1', 'byte');
my @Speech_PacTac2 = $SpeechFile->val('speech_PacTac2', 'byte');
my @Speech_PacTac3 = $SpeechFile->val('speech_PacTac3', 'byte');
my $Pending_VA = 0;
my $VA_Message = 0;
print "Done.\n";
print "----------------------------------------------------------------------\n";



# Connect to Priority and scan TGs.
my $LinkedTalkGroup = $PriorityTG;
my $PriorityTGActive = 0;
my $MuteTGTimer = time();
foreach my $key (keys %TG) {
	if ($TG{$key}{'Scan'}) {
		AddLinkTG($key);
	}
}
if ($PriorityTG > 10 and !$TG{$PriorityTG}{'Scan'}) {
	$TG{$PriorityTG}{'Scan'} = 10;
	AddLinkTG($PriorityTG);
}
print "----------------------------------------------------------------------\n";



# Prepare Startup VA Message.
$VA_Message = 0; # 0 = Welcome to the P25NX.
$Pending_VA = 1; # Let the system know we wish a Voice Announce when possible.



# Raspberry Pi GPIO
#my $ResetPicPin = RPi::Pin->new(4, "Reset PIC");
#my $Pin5 = RPi::Pin->new(5, "PTT");
#my $Pin5 = RPi::Pin->new(6, "COS");
# This use the BCM pin numbering scheme. 
# Valid GPIOs are: 2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27.
# GPIO 2, 3 Aleternate for I2C.
# GPIO 14, 15 alternate for USART.
#$ResetPicPin->mode(OUTPUT);
#$Pin5->write(HIGH);
#$pin->set_interrupt(EDGE_RISING, 'main::Pin5_Interrupt_Handler');



# Init Cisco STUN TCP
print "Init Cisco STUN.\n";
my $STUN_ID = sprintf("%x", hex($cfg->val('STUN', 'STUN_ID')));
my $STUN_Verbose =$cfg->val('STUN', 'Verbose');
print "  Stun ID = 0x$STUN_ID\n";
print "  Verbose = $STUN_Verbose\n";
my $STUN_ServerSocket;
my $STUN_Port = 1994; # Cisco STUN port is 1994;
my $STUN_Connected = 0;
my $STUN_Sel;
my $STUN_ClientSocket;
my $STUN_ClientAddr;
my $STUN_ClientPort;
my $STUN_ClientIP;
my $STUN_fh;

$STUN_ServerSocket = IO::Socket::INET->new (
    LocalHost => '172.31.7.162',
    LocalPort => $STUN_Port,
    Proto => 'tcp',
    Listen => SOMAXCONN,
    ReuseAddr =>1,
    Blocking => 0
) or die "  cannot create CiscoUSTUN_ServerSocket $!\n";
print "  Server waiting for client connection on port " . $STUN_Port . ".\n";

# Set timeouts -- may not really be needed
IO::Socket::Timeout->enable_timeouts_on($STUN_ServerSocket);
$STUN_ServerSocket->read_timeout(0.0001);
$STUN_ServerSocket->write_timeout(0.0001);
my $STUN_DataIndex = 0;
my @STUN_Data = [];

print "----------------------------------------------------------------------\n";



# Read Keys:
if ($HotKeys) {
	ReadMode 3;
	PrintMenu();
}
print "----------------------------------------------------------------------\n";



# Misc
my $Run = 1;



###################################################################
# MAIN ############################################################
###################################################################
if ($Mode == 1) { # If Cisco STUN (Mode 1) is selected:
	print "Cisco STUN listen for connections:\n";
	while ($Run) {
		#if($STUN_ClientAddr = accept($STUN_ClientSocket, $STUN_ServerSocket)) {
		if(($STUN_ClientSocket, $STUN_ClientAddr) = $STUN_ServerSocket->accept()) {
			my ($Client_Port, $Client_IP) = sockaddr_in($STUN_ClientAddr);
			$STUN_ClientIP = inet_ntoa($Client_IP);
			print "STUN_Client IP " . inet_ntoa($Client_IP) . 
				":" . $STUN_Port . "\n";

			$STUN_ClientSocket->autoflush(1);
			$STUN_Sel = IO::Select->new($STUN_ClientSocket);
			$STUN_Connected = 1;

#			$STUN_ClientSocket->recv(my $Buffer, $MaxLen);
#			$STUN_ClientSocket->send($Buffer);

			MainLoop();

		}
	}
	$STUN_ServerSocket->close();
} else { # If Serial (Mode 0) is selected: 
	MainLoop();
}
# Program exit:
print "----------------------------------------------------------------------\n";
ReadMode 0; # Set keys back to normal State.
if ($Mode == 0) { # Close Serial Port:
	$SerialPort->close || die "Failed to close SerialPort.\n";
}
foreach my $key (keys %TG){ # Close Socket connections:
	if ($TG{$key}{'MMDVM_Connected'}) {
		WriteUnlink($TG{$key}{'MMDVM_TalkGroup'});
		$TG{$key}{'Sock'}->close();
	}
	if ($TG{$key}{'P25NX_Connected'}) {
		P25NX_Disconnect($TG{$key}{'P25NX_TalkGroup'});
		$TG{$key}{'Sock'}->close();
	}
	if ($TG{$key}{'P25Link_Connected'}) {
		P25Link_Disconnect($TG{$key}{'P25Link_TalkGroup'});
		$TG{$key}{'Sock'}->close();
	}
}
print "Good bye cruel World.\n";
print "----------------------------------------------------------------------\n";
exit;

##################################################################
# Menu ###########################################################
##################################################################
sub PrintMenu {
	print "Shortcuts:\n";
	print "  Q/q = Quit.                      h = Help..\n";
	print "  H/h = HDLC  show/hide verbose.   \n";
	print "  J/j = JSON  show/hide verbose.   M/m = MMDVM   show/hide verbose.\n";
	print "  P/p = P25NX show/hide verbose.   L/l = P25Link show/hide verbose.\n";
	print "  t = Test.               \n\n";

}

##################################################################
# Serial #########################################################
##################################################################
sub Read_Serial{ # Read the serial port, look for 0x7E characters and extract data between them.
	my $NumChars;
	my $SerialBuffer;
	($NumChars, $SerialBuffer) = $SerialPort->read(255);
	if ($NumChars >= 1 ){ #Perl data Arrival test.
		#Bytes_2_HexString($SerialBuffer);
		for (my $x = 0; $x <= $NumChars; $x++) {
			if (ord(substr($SerialBuffer, $x, 1)) == 0x7E) {
				if (length($HDLC_Buffer) > 0) {
					HDLC_Rx($HDLC_Buffer, 0); # Process a full data stream.
					#print "Serial Str Data Rx len() = " . length($HDLC_Buffer) . "\n";
				}
				#print "Read_Serial len = ", length($HDLC_Buffer), "\n";
				$HDLC_Buffer = ""; # Clear Rx buffer.
			} else {
				# Add Bytes until the end of data stream (0x7E):
				$HDLC_Buffer = $HDLC_Buffer . substr($SerialBuffer, $x, 1);
			}
		}
	}
}

##################################################################
# HDLC ###########################################################
##################################################################
sub HDLC_Rx{
	my ($Buffer, $Index, $RemoteHostIP) = @_;
	my $RTRTOn;
	my $OpCode;
	my $OpArg;
	my $SiteID;
	my $IsChannelChange;
	my $Channel;
	my $IsStart;
	my $IsEnd;

	if ($Mode == 0) { # Serial Mode
		# CRC CCITT test patterns:
		#my $DataC;
		#$DataC = "7EFD01BED27E"; # RR
		#$DataC = "7EFD3F430A7E"; # SABM
		#$Buffer = chr(0x7E) . chr(0xFD) . chr(0x3F) . chr(0x43) . chr(0x0A) . chr(0x7E);
		#$Buffer = chr(0x7E) . chr(0xFD) . chr(0x03) . chr(0x00) . chr(0x00) . 
			#chr(0x7D) . chr(0x5E) . 
			#chr(0x11) . chr(0x11) .
			#chr(0x7D) . chr(0x5D) . chr(0x22) . chr(0x22) . 
			#chr(0x7D) . chr(0x45) . chr(0x33) . chr(0x33) .
			#chr(0x7E);	

		#$Buffer = chr(0x7E) . $Buffer . chr(0x7E);

		#print "A ", sprintf("0x%x", ord(substr($Buffer, 0, 1))), "\n";
		#print "B ", sprintf("0x%x", ord(substr($Buffer, 1, 1))), "\n";
		#print "C ", sprintf("0x%x", ord(substr($Buffer, 2, 1))), "\n";
		#print "D ", sprintf("0x%x", ord(substr($Buffer, 3, 1))), "\n";
		#print "E ", sprintf("0x%x", ord(substr($Buffer, 4, 1))), "\n";
		#print "F ", sprintf("0x%x", ord(substr($Buffer, 5, 1))), "\n";
	
		#print "Buffer = $Buffer\n";
		#print "Len(Buffer) = ", length($Buffer), "\n";
		#my $res = HexStr_2_Str($Buffer);

		if (substr($Buffer, 0, 7) eq "!RESET!") {
			my $BoardID = ord(substr($Buffer, 7, 1));
			print "*** Warning ***   HDLC_Rx Board $BoardID made a Reset!\n";
			return;
		}

		# Byte Stuff
		$Buffer =~ s/\}\^/\~/g; # 0x7D 0x5E to 0x7E
		$Buffer =~ s/\}\]/\}/g; # 0x7D 0x5D to 0x7D
		#print "Byte Stuff, Len(Buffer) = ", length($Buffer), "\n";
		
		# Show Raw data.
		#Bytes_2_HexString($Buffer);
	
		# CRC CCITT.
		if (length($Buffer) < 2) {
			print "*** Warning ***   HDLC_Rx Warning Buffer < 2 Bytes.\n";
			return;
		}
		$Message = substr($Buffer, 0, length($Buffer) - 2);
		#print "Len(Message) = ", length($Message), "\n";
		my $CRC_Rx = 256 * ord(substr($Buffer, length($Buffer) - 2, 1 )) + 
			ord(substr($Buffer, length($Buffer) - 1, 1));
		#print "CRC_Rx  = $CRC_Rx\n";
		if (length($Message) == 0) {
			print "*** Warning ***   HDLC_Rx Message is Null.\n";
			return;
		}
		my $CRC_Gen = CRC_CCITT_Gen($Message);
		#print "CRC_Gen = $CRC_Gen\n";
		#print "CRCH ", sprintf("0x%x", ord(substr($CRC_Gen, 0, 1))), "\n";
		#print "CRCL ", sprintf("0x%x", ord(substr($CRC_Gen, 1, 1))), "\n";
		#print "Calc CRC16 in hex: ", unpack('H*', pack('S', $Message)), "\n";
		if ($CRC_Rx != $CRC_Gen) {
			print "*** Warning ***   HDLC_Rx CRC does not match " . $CRC_Rx . " <> " . $CRC_Gen . ".\n";
			return;
		}
	} else {
		$Message = $Buffer,
	}

	if ($HDLC_Verbose >= 3) {
		print "HDLC_Rx Message.\n";
		Bytes_2_HexString($Message);
	}
	# 01 Address
	my $Address = ord(substr($Message, 0, 1));
	#print "Address = ", sprintf("0x%x", $Address), "\n";
	#Bytes_2_HexString($Message);
	
	$Quant{$Index}{'FrameType'} = ord(substr($Message, 1, 1));
	#print "Frame Types = ", sprintf("0x%x", $FrameType), "\n";
	switch ($Quant{$Index}{'FrameType'}) {
		case 0x01 { # RR Receive Ready.
			if ($Address == 253) {
				$RR_Timer = 0;
				$HDLC_Handshake = 1;
			} else {
				print "*** Warning ***   HDLC_Rx RR Address 253 != $Address\n";
			}
			return;
		}
		case 0x03 { # User Information.
			#print "Case 0x03 UI.", substr($Message, 2, 1), "\n";
			#Bytes_2_HexString($Message);
			$Quant{$Index}{'LocalRx'} = 1;
			$Quant{$Index}{'LocalRx_Time'} = getTickCount();
			switch (ord(substr($Message, 2, 1))) {
				case 0x00 { #Network ID, NID Start/Stop.
					if ($HDLC_Verbose) {
						print "UI 0x00 NID Start/Stop";
					}
					if (ord(substr($Message, 4, 1)) == $C_RTRT_Enabled) {
						$RTRTOn = 1;
						if ($HDLC_Verbose) {
							print ", RT/RT Enabled";
						}
					}
					if (ord(substr($Message, 4, 1)) == $C_RTRT_Disabled) {
						$RTRTOn = 0;
						if ($HDLC_Verbose) {
							print ", RT/RT Disabled";
						}
					}
					$OpCode = ord(substr($Message, 5, 1));
					$OpArg = ord(substr($Message, 6, 1));
					switch ($OpCode) {
						case 0x06 { # ChannelChange
							$IsChannelChange = 1;
							$Channel = $OpArg;
						}
						case 0x0C { # StartTx
							$IsStart = 1;
							if ($HDLC_Verbose) {
								print ", HDLC ICW Start";
							}
							Tx_to_Network($Message);
						}
						case 0x0D {
							if ($HDLC_Verbose) {
								print ", DIU Monitor";
							}
						}
						case 0x25 { # StopTx
							$IsEnd = 1;
							if ($HDLC_Verbose) {
								print ", HDLC ICW Terminate";
							}
							$Quant{$Index}{'LocalRx'} = 0;
							Tx_to_Network($Message);
						}
					}
					switch ($OpArg) {
						case 0x00 { # AVoice
							 if ($HDLC_Verbose) {print ", Analog Voice";}
						}
						case 0x0B { # DVoice
							 if ($HDLC_Verbose) {print ", Digital Voice";}
						}
						case 0x0F { # Page
							 if ($HDLC_Verbose) {print ", Page";}
						}
					}
					if ($HDLC_Verbose) {
						print ", Linked Talk Group " . $LinkedTalkGroup . ".\n";
						#print "MMDVM_Connected " . $MMDVM_Connected . 
						#"\nP25NX_Connected " . $P25NX_Connected;
						print "\n";
					}
				}
				case 0x01 {
					print "UI 0x01 Undefined.\n";
				}
				case 0x59 {
					print "UI 0x59 Undefined.\n";
					return;
				}
				case 0x60 {
					if ($HDLC_Verbose) {print "UI 0x60 Voice Header part 1.\n";}
					Bytes_2_HexString($Buffer);
					switch (ord(substr($Message, 4, 1))) {
						case 0x02 { # RTRT_Enabled
							$RTRTOn = 1;
							if ($HDLC_Verbose) {print "RT/RT Enabled";}
						}
						case 0x04 { # RTRT_Disabled
							$RTRTOn = 1;
							if ($HDLC_Verbose) {print "RT/RT Disabled";}
						}
					}
					switch (ord(substr($Message, 6, 1))) {
						case 0x00 { # AVoice
							if ($HDLC_Verbose) {print ", Analog Voice";}
						}
						case 0x0B { # DVoice
							if ($HDLC_Verbose) {print ", Digital Voice";}
						}
						case 0x0F { # Page
							if ($HDLC_Verbose) {print ", Page";}
						}
					}
					$SiteID = ord(substr($Message,7 ,1));
					switch ($SiteID) {
						case 0x00 { # DIU3000
							if ($HDLC_Verbose) {print ", Source: DIU 3000";}
						}
						case 0xC2 { # Quantar
							if ($HDLC_Verbose) {print ", Source: Quantar";}
						}
					}
					if (ord(substr($Message, 9, 1)) == 1) {
						$Quant{$Index}{'RSSI_Is_Valid'} = 1;
						$Quant{$Index}{'RSSI'} = ord(substr($Message, 8, 1));
						$Quant{$Index}{'InvertedSignal'} = ord(substr($Message, 10, 1));
						if ($HDLC_Verbose) {
							print ", RSSI = " . $Quant{$Index}{'RSSI'} . "\n";
							print ", Inverted signal = " . $Quant{$Index}{'InvertedSignal'} . "\n";
						}
					} else {
						$Quant{$Index}{'RSSI_Is_Valid'} = 0;
						if ($HDLC_Verbose) {print ".\n";}
					}
				}
				case 0x61 {
					if ($HDLC_Verbose) {
						print "UI 0x61 Voice Header part 2.\n";
					}
					if ($HDLC_Verbose == 2) {
						Bytes_2_HexString($Message);
					}
					#my $TGID = 256 * ord(substr($Message, 4, 1)) + ord(substr($Message, 3, 1));;
					#print "Not true TalkGroup ID = " . $TGID . "\n";

				}
				case 0x62 { # dBm, RSSI, BER.
					if ($HDLC_Verbose) {print "UI 0x62 IMBE Voice part 1.\n";}
					switch (ord(substr($Message, 4, 1))) {
						case 0x02 { # RT/RT Enable
							$RTRTOn = 1;
							if ($HDLC_Verbose) {print "RT/RT Enabled";}
						}
						case 0x04 { # RT/RT Disable
							$RTRTOn = 0;
							if ($HDLC_Verbose) {print "RT/RT Disabled";}
						}
					}
					switch (ord(substr($Message, 6, 1))) {
						case 0x0B { # DVoice
							$Quant{$Index}{'IsDigitalVoice'} = 1;
							$Quant{$Index}{'IsPage'} = 0;
							if ($HDLC_Verbose) {print ", Digital Voice";}
						}
						case 0x0F { # Page
							$Quant{$Index}{'IsDigitalVoice'} = 0;
							$Quant{$Index}{'IsPage'} = 1;
							if ($HDLC_Verbose) {print ", Page";}
						}
					}
					$SiteID = ord(substr($Message, 7, 1));
					switch ($SiteID) {
						case 0x00 { # DIU3000
							if ($HDLC_Verbose) {print ", SiteID: DIU 3000";}
						}
						case 0xC2 { # Quantar
							if ($HDLC_Verbose) {print ", SiteID: Quantar";}
						}
					}
					if (ord(substr($Message, 9, 1))) {
						$Quant{$Index}{'RSSI_Is_Valid'} = 1;
						$Quant{$Index}{'RSSI'} = ord(substr($Message, 8, 1));
						$Quant{$Index}{'InvertedSignal'} = ord(substr($Message, 10, 1));
						$Quant{$Index}{'CandidateAdjustedMM'} = ord(substr($Message, 11, 1));
						if ($HDLC_Verbose) {
							print ", RSSI = " . $Quant{$Index}{'RSSI'};
							print ", Inverted signal = " . $Quant{$Index}{'InvertedSignal'};
						}
					} else {
						$Quant{$Index}{'RSSI_Is_Valid'} = 0;
					}
					if ($HDLC_Verbose) {print "\n";}
					$Quant{$Index}{'Speech'} = ord(substr($Message, 12, 11));
					$Quant{$Index}{'Raw0x62'} = $Message;
					$Quant{$Index}{'SuperFrame'} = $Message;
					$Quant{$Index}{'SourceDev'} = ord(substr($Message, 23, 1));
					Tx_to_Network($Message);

				}
				case 0x63 {
					if ($HDLC_Verbose) {print "UI 0x63 IMBE Voice part 2.\n";}
					$Quant{$Index}{'Speech'} = ord(substr($Message, 3, 11));
					$Quant{$Index}{'Raw0x63'} = $Message;
					$Quant{$Index}{'SuperFrame'} = $Quant{$Index}{'SuperFrame'} . $Message;
					$Quant{$Index}{'SourceDev'} = ord(substr($Message, 14, 1));
					Tx_to_Network($Message);
				}
				case 0x64 { # Group/Direct Call, Clear/Private.
					if ($HDLC_Verbose) {print "UI 0x64 IMBE Voice part 3 + link control.\n";}
					if (ord(substr($Message, 3, 1)) & 0x80) {
						$Quant{$Index}{'Encrypted'} = 1;
					}
					if (ord(substr($Message, 3, 1))& 0x40) {
						$Quant{$Index}{'Explicit'} = 1;
					}
					$Quant{$Index}{'IsTGData'} = 0;
					switch (ord(substr($Message, 3, 1)) & 0x0F) {
						case 0x00 { # Group voice channel user.
							$Quant{$Index}{'IsTGData'} = 1;
							$Quant{$Index}{'IndividualCall'} = 0;
						}
						case 0x02 { # Group voice channel update.
							$Quant{$Index}{'IndividualCall'} = 0;
						}
						case 0x03 { # Unit to unit voice channel user.
							$Quant{$Index}{'IndividualCall'} = 1;
						}
						case 0x04 { # Group voice channel update - explicit.
							$Quant{$Index}{'IndividualCall'} = 1;
						}
						case 0x05 { # Unit to unit answer request.
							$Quant{$Index}{'IndividualCall'} = 1;
						}
						case 0x06 { # Telephone interconnect voice channel user.
							print "Misterious packet.";
						}
						case 0x07 { # Telephone interconnect answer request.
							print "Telephone interconnect answer request.\n";
						}
						case 0x0F { # Call termination/cancellation.
							print "Call termination/cancellation.\n";
						}

					}
					$Quant{$Index}{'ManufacturerID'} = ord(substr($Message, 4, 1));
					if (ord(substr($Message, 5, 1)) and 0x80) {
						$Quant{$Index}{'Emergency'} = 1;
					} else {
						$Quant{$Index}{'Emergency'} = 0;
					}
					if (ord(substr($Message, 5, 1)) and 0x40) {
						$Quant{$Index}{'Protected'} = 1;
					} else {
						$Quant{$Index}{'Protected'} = 0;
					}
					if (ord(substr($Message, 5, 1)) and 0x20) {
						$Quant{$Index}{'FullDuplex'} = 1;
					} else {
						$Quant{$Index}{'FullDuplex'} = 0;
					}
					if (ord(substr($Message, 5, 1)) and 0x10) {
						$Quant{$Index}{'PacketMode'} = 1;
					} else {
						$Quant{$Index}{'PacketMode'} = 0;
					}
					$Quant{$Index}{'Priority'} = ord(substr($Message, 5, 1));
					$Quant{$Index}{'Speech'} = ord(substr($Message, 7, 11));
					$Quant{$Index}{'SuperFrame'} = $Quant{$Index}{'SuperFrame'} . $Message;
					$Quant{$Index}{'Raw0x64'} = $Message;
					Tx_to_Network($Message);
				}
				case 0x65 { # Talk Group.
					if ($HDLC_Verbose) {print "UI 0x65 IMBE Voice part 4 + link control.\n";}
					#Bytes_2_HexString($Message);
					if ($Quant{$Index}{'IsTGData'} == 1) {
						my $MMSB = ord(substr($Message, 3, 1));
						my $MSB = ord(substr($Message, 4, 1));
						my $LSB = ord(substr($Message, 5, 1));
						$Quant{$Index}{'AstroTalkGroup'} = ($MSB << 8) | $LSB;
						$Quant{$Index}{'DestinationRadioID'} = ($MMSB << 16) | ($MSB << 8) | $LSB;

						# Leave previous line empty.
						if ($Quant{$Index}{'IndividualCall'}) {
							if ($HDLC_Verbose) {
								print "Destination ID = " . $Quant{$Index}{'DestinationID'} . "\n";
							}
						} else {
							if ($HDLC_Verbose) {
								print "AstroTalkGroup = " . $Quant{$Index}{'AstroTalkGroup'} . "\n";
							}
							AddLinkTG($Quant{$Index}{'AstroTalkGroup'});
						}
					}
					$Quant{$Index}{'Speech'} = ord(substr($Message, 7, 11));
					$Quant{$Index}{'Raw0x65'} = $Message;
					$Quant{$Index}{'SuperFrame'} = $Quant{$Index}{'SuperFrame'} . $Message;
					Tx_to_Network($Message);
				}
				case 0x66 { # Source ID.
					if ($HDLC_Verbose) {print "UI 0x66 IMBE Voice part 5. + link control.\n";}
					# Get Called ID.
					if ($Quant{$Index}{'IsTGData'}) {
						my $MMSB = ord(substr($Message, 3, 1));
						my $MSB = ord(substr($Message, 4, 1));
						my $LSB = ord(substr($Message, 5, 1));
						$Quant{$Index}{'SourceRadioID'} = ($MMSB << 16) | ($MSB << 8) | $LSB;

						# Leave previous line empty.
						if ($HDLC_Verbose) {
							print "HDLC SourceRadioID = " . $Quant{$Index}{'SourceRadioID'} . "\n";
						}
						#QSO_Log($Index, $RemoteHostIP);
					} else {
						if ($Verbose) {print "Misterious packet 0x66\n";}
					}
					$Quant{$Index}{'Speech'} = ord(substr($Message, 7, 11));
					$Quant{$Index}{'Raw0x66'} = $Message;
					$Quant{$Index}{'SuperFrame'} = $Quant{$Index}{'SuperFrame'} . $Message;
					Tx_to_Network($Message);
				}
				case 0x67 { # TBD
					if ($HDLC_Verbose) {print "UI 0x67 IMBE Voice part 6 + link control.\n";}
					$Quant{$Index}{'Speech'} = ord(substr($Message, 7, 11));
					$Quant{$Index}{'Raw0x67'} = $Message;
					$Quant{$Index}{'SuperFrame'} = $Quant{$Index}{'SuperFrame'} . $Message;
					Tx_to_Network($Message);
				}
				case 0x68 {
					if ($HDLC_Verbose) {print "UI 0x68 IMBE Voice part 7 + link control.\n";}
					$Quant{$Index}{'Speech'} = ord(substr($Message, 7, 11));
					$Quant{$Index}{'Raw0x68'} = $Message;
					$Quant{$Index}{'SuperFrame'} = $Quant{$Index}{'SuperFrame'} . $Message;
					Tx_to_Network($Message);
				}
				case 0x69 {
					if ($HDLC_Verbose) {print "UI 0x69 IMBE Voice part 8 + link control.\n";}
					$Quant{$Index}{'Speech'} = ord(substr($Message, 7, 11));
					$Quant{$Index}{'Raw0x69'} = $Message;
					$Quant{$Index}{'SuperFrame'} = $Quant{$Index}{'SuperFrame'} . $Message;
					Tx_to_Network($Message);
				}
				case 0x6A { # Low speed data Byte 1.
					if ($HDLC_Verbose) {print "UI 0x6A IMBE Voice part 9 + low speed data 1.\n";}
					$Quant{$Index}{'LSD0'} = ord(substr($Message, 4, 1));
					$Quant{$Index}{'LSD1'} = ord(substr($Message, 5, 1));
					$Quant{$Index}{'Speech'} = ord(substr($Message, 6, 11));
					$Quant{$Index}{'Raw0x6A'} = $Message;
					$Quant{$Index}{'SuperFrame'} = $Quant{$Index}{'SuperFrame'} . $Message;
					Tx_to_Network($Message);
				}
				case 0x6B { # dBm, RSSI, BER.
					if ($HDLC_Verbose) {print "UI 0x6B IMBE Voice part 10.\n";}
					switch (ord(substr($Message, 4, 1))) {
						case 0x02 { # RT/RT Enable
							$RTRTOn = 1;
							if ($HDLC_Verbose) {print "RT/RT Enabled";}
						}
						case 0x04 { # RT/RT Disable
							$RTRTOn = 0;
							if ($HDLC_Verbose) {print "RT/RT Disabled";}
						}
					}
					switch (ord(substr($Message, 6, 1))) {
						case 0x0B { # DVoice
							$Quant{$Index}{'IsDigitalVoice'} = 1;
							$Quant{$Index}{'IsPage'} = 0;
							if ($HDLC_Verbose) {print ", Digital Voice";}
						}
						case 0x0F { # Page
							$Quant{$Index}{'IsDigitalVoice'} = 0;
							$Quant{$Index}{'IsPage'} = 1;
							if ($HDLC_Verbose) {print ", Page";}
						}
					}
					$SiteID = ord(substr($Message, 7, 1));
					switch ($SiteID) {
						case 0x00 { # DIU3000
							if ($HDLC_Verbose) {print ", SiteID: DIU 3000";}
						}
						case 0xC2 { # Quantar
							if ($HDLC_Verbose) {print ", SiteID: Quantar";}
						}
					}
					$Quant{$Index}{'RSSI'} = ord(substr($Message, 8, 1));
					if (ord(substr($Message, 9, 1))) {
						$Quant{$Index}{'RSSI_Is_Valid'} = 1;
						if ($HDLC_Verbose) {
							print ", RSSI = " . $Quant{$Index}{'RSSI'};
							print ", Inverted signal = " . $Quant{$Index}{'InvertedSignal'};
						}
					} else {
						$Quant{$Index}{'RSSI_Is_Valid'} = 0;
					}
					if ($HDLC_Verbose) {print "\n";}
					$Quant{$Index}{'InvertedSignal'} = ord(substr($Message, 10, 1));
					$Quant{$Index}{'CandidateAdjustedMM'} = ord(substr($Message, 11, 1));
					$Quant{$Index}{'Speech'} = ord(substr($Message, 12, 11));
					$Quant{$Index}{'Raw0x6B'} = $Message;
					$Quant{$Index}{'SourceDev'} = ord(substr($Message, 23, 1));
					$Quant{$Index}{'SuperFrame'} = $Message;
					Tx_to_Network($Message);
				}
				case 0x6C {
					if ($HDLC_Verbose) {print "UI 0x6C IMBE Voice part 11.\n";}
					$Quant{$Index}{'Speech'} = ord(substr($Message, 3, 11));
					$Quant{$Index}{'Raw0x6C'} = $Message;
					$Quant{$Index}{'SuperFrame'} = $Quant{$Index}{'SuperFrame'} . $Message;
					Tx_to_Network($Message);
				}
				case 0x6D {
					if ($HDLC_Verbose) {print "UI 0x6D IMBE Voice part 12 + encryption sync.\n";}
					$Quant{$Index}{'EncryptionI'} = ord(substr($Message, 3, 4));
					$Quant{$Index}{'Speech'} = ord(substr($Message, 7, 11));
					$Quant{$Index}{'Raw0x6D'} = $Message;
					$Quant{$Index}{'SuperFrame'} = $Quant{$Index}{'SuperFrame'} . $Message;
					Tx_to_Network($Message);
				}
				case 0x6E {
					if ($HDLC_Verbose) {print "UI 0x6E IMBE Voice part 13 + encryption sync.\n";}
					$Quant{$Index}{'EncryptionII'} = ord(substr($Message, 3,4));
					$Quant{$Index}{'Speech'} = ord(substr($Message, 7, 11));
					$Quant{$Index}{'Raw0x6E'} = $Message;
					$Quant{$Index}{'SuperFrame'} = $Quant{$Index}{'SuperFrame'} . $Message;
					Tx_to_Network($Message);
				}
				case 0x6F {
					if ($HDLC_Verbose) {print "UI 0x6F IMBE Voice part 14 + encryption sync.\n";}
					$Quant{$Index}{'EncryptionIII'} = ord(substr($Message, 3,4));
					$Quant{$Index}{'Speech'} = ord(substr($Message, 7, 11));
					$Quant{$Index}{'Raw0x6F'} = $Message;
					$Quant{$Index}{'SuperFrame'} = $Quant{$Index}{'SuperFrame'} . $Message;
					Tx_to_Network($Message);
				}
				case 0x70 { # Algorithm.
					if ($HDLC_Verbose) {print "UI 0x70 IMBE Voice part 15 + encryption sync.\n";}
					$Quant{$Index}{'Algorythm'} = ord(substr($Message, 3,1));
					$Quant{$Index}{'KeyID'} = ord(substr($Message, 4,2));
					$Quant{$Index}{'Speech'} = ord(substr($Message, 7, 11));
					$Quant{$Index}{'Raw0x70'} = $Message;
					$Quant{$Index}{'SuperFrame'} = $Quant{$Index}{'SuperFrame'} . $Message;
					Tx_to_Network($Message);
				}
				case 0x71 {
					if ($HDLC_Verbose) {print "UI 0x71 IMBE Voice part 16 + encryption sync.\n";}
					$Quant{$Index}{'Speech'} = ord(substr($Message, 7, 11));
					$Quant{$Index}{'Raw0x71'} = $Message;
					$Quant{$Index}{'SuperFrame'} = $Quant{$Index}{'SuperFrame'} . $Message;
					Tx_to_Network($Message);
				}
				case 0x72 {
					if ($HDLC_Verbose) {print "UI 0x72 IMBE Voice part 17 + encryption sync.\n";}
					$Quant{$Index}{'Speech'} = ord(substr($Message, 7, 11));
					$Quant{$Index}{'Raw0x72'} = $Message;
					$Quant{$Index}{'SuperFrame'} = $Quant{$Index}{'SuperFrame'} . $Message;
					Tx_to_Network($Message);
				}
				case 0x73 { # Low speed data Byte 2.
					if ($HDLC_Verbose) {print "UI 0x73 IMBE Voice part 18 + low speed data 2.\n";}
					$Quant{$Index}{'LSD2'} = ord(substr($Message, 4, 1));
					$Quant{$Index}{'LSD3'} = ord(substr($Message, 5, 1));
					$Quant{$Index}{'Speech'} = ord(substr($Message, 6, 11));
					$Quant{$Index}{'Raw0x73'} = $Message;
					$Quant{$Index}{'SuperFrame'} = $Quant{$Index}{'SuperFrame'} . $Message;
					Tx_to_Network($Message);
				}
				case 0x80 {
					print "UI 0x80.\n";
					Bytes_2_HexString($Message);
				}
				case 0x85 {
					print "UI 0x85.\n";
					Bytes_2_HexString($Message);
				}
				case 0x87 {
					print "UI 0x87.\n";
					Bytes_2_HexString($Message);
				}
				case 0x88 {
					print "UI 0x88.\n";
					Bytes_2_HexString($Message);
				}
				case 0x8D {
					print "UI 0x8D.\n";
					Bytes_2_HexString($Message);
				}
				case 0x8F {
					print "UI 0x8F.\n";
					Bytes_2_HexString($Message);
				}
				case 0xA1 { # Page affliate request.
					print "UI 0xA1.\n";
					Bytes_2_HexString($Message);
				} else {
					print "UI else 0x" . ord(substr($Message, 2, 1)) . "\n";
					Bytes_2_HexString($Message);
				}
			}
		}
		case 0x3F { # SABM Rx
			if ($HDLC_Verbose) {print "HDLC_Rx SABM.\n";}
			if ($HDLC_Verbose == 2) {Bytes_2_HexString($Message);}
			$HDLC_Handshake = 0;
			$RR_Timer = 0;
			if ($HDLC_Verbose > 1) {print "  Calling HDLC_Tx_UA\n";}
			HDLC_Tx_UA(253);
			$SABM_Counter = $SABM_Counter + 1;
			if ($SABM_Counter > 3) {
				HDLC_Tx_Reset();
				$SABM_Counter = 0;
			}
		}
		case 0x73 { #
			if ($HDLC_Verbose) {print "HDLC_Rx UA (case 0x73 Unumbered Ack).\n";}
			if ($HDLC_Verbose == 2) {Bytes_2_HexString($Message);}
		}
		case 0xBF { # XID Quantar to DIU identification packet.
			if ($HDLC_Verbose) {print "HDLC_Rx XID.\n";}
			if ($HDLC_Verbose == 2) {Bytes_2_HexString($Message);}
			$SABM_Counter = 0;
			my $MessageType = ord(substr($Message, 2, 1));
			my $StationSiteNumber = (int(ord(substr($Message, 3, 1))) - 1) / 2;
			my $StationType = ord(substr($Message, 4, 1));
			if ($StationType == $C_Quantar) {
				if ($HDLC_Verbose > 1) {print "  Station type = Quantar.\n";}
			}
			if ($StationType == $C_DIU3000) {
				if ($HDLC_Verbose > 1) {print "  Station type = DIU3000.\n";}
			}
			if ($HDLC_Verbose > 1) {print "  Calling HDLC_Tx_XID\n";}
			HDLC_Tx_XID(0x0B);
			$HDLC_Handshake = 1;
			$RR_Timer = 1;
			if ($HDLC_Verbose > 1) {print "  Calling HDLC_Tx_RR\n";}
			HDLC_Tx_RR();
		}
	}
	if ($HDLC_Verbose) {
		print "----------------------------------------------------------------------\n";
	}
}


sub HDLC_Tx{
	my ($Data) = @_;
	my $CRC;
	my $MSB;
	my $LSB;
	# Serial mode = 0;
	if ($Mode == 0) {
		if ($HDLC_Verbose) {print "HDLC_Tx.\n";}
		if ($HDLC_Verbose > 1) {Bytes_2_HexString($Data);}
		$CRC = CRC_CCITT_Gen($Data);
		$MSB = int($CRC / 256);
		$LSB = $CRC - $MSB * 256;
		$Data = $Data . chr($MSB) . chr($LSB);
		# Byte Stuff
		$Data =~ s/\}/\}\]/g; # 0x7D to 0x7D 0x5D
		$Data =~ s/\~/\}\^/g; # 0x7E to 0x7D 0x5E
		if ($HDLC_Verbose >= 2) {print "Len(Data) = ", length($Data), "\n";}
		$SerialPort->write($Data . chr(0x7E));
		my $SerialWait = (8.0 / 9600.0) * length($Data); # Frame length delay.
		nanosleep($SerialWait * 1000000000);
		if ($HDLC_Verbose) {print "Serial nanosleep = $SerialWait\n";}
	}
	# STUN mode = 1;
	if ($Mode == 1) {
		STUN_Tx($Data);
	}
	if ($HDLC_Verbose) {print "HDLC_Tx Done.\n";}
}

sub HDLC_Tx_Reset{
	if ($Mode == 0) {
		#$serialport->write(chr(0x7D) . chr(0xFF));
		$SerialPort->pulse_rts_on(50);
		$HDLC_TxTraffic = 0; 
		print "HDLC_Tx_Reset Sent.\n";
	}
}

sub HDLC_Tx_UA{
	my ($Address) = @_;
	if ($HDLC_Verbose) {print "HDLC_Tx_UA.\n";}
	my $Data = chr($Address) . chr(0x73);
	HDLC_Tx ($Data);
}

sub HDLC_Tx_XID{
	my ($Address) = @_;
	if ($HDLC_Verbose) {print "HDLC_Tx_XID.\n";}
	my $ID = 13;
	my $Data = chr($Address) . chr(0xBF) . chr(0x01) . chr($ID * 2 + 1) . chr(0x00) . 
		chr(0x00) . chr(0x00) . chr(0x00) . chr(0x00) . chr(0xFF);
	HDLC_Tx ($Data);
}

sub HDLC_Tx_RR{
	my $Data;
	if ($HDLC_Verbose) {print "HDLC_Tx_RR.\n";}
	$Data = chr(253) . chr(0x01);
	HDLC_Tx ($Data);
}

sub Bytes_2_HexString{
	my ($Buffer) = @_;
	# Display Rx Hex String.
	#print "HDLC_Rx Buffer:              ";
	for (my $x = 0; $x < length($Buffer); $x++) {
		print sprintf(" %x", ord(substr($Buffer, $x, 1)));
	}
	print "\n";
}

sub CRC_CCITT_Gen{
	my ($Buffer) = @_;
	my $ctx = Digest::CRC->new(type=>"crcccitt");
	$ctx = Digest::CRC->new(width=>16, init=>0xFFFF, xorout=>0xFFFF,
	refout=>1, poly=>0x1021, refin=>1, cont=>0);
	$ctx->add($Buffer);
	my $digest = $ctx->digest;
	my $MSB = int($digest / 256);
	my $LSB = $digest - $MSB * 256;
	$digest = 256 * $LSB + $MSB;
	return $digest;
}



##################################################################
# Cisco STUN  ####################################################
##################################################################
sub STUN_Tx{
	my ($Buffer) = @_;
	my $STUN_Header = chr(0x08) . chr(0x31) . chr(0x00) . chr(0x00) . chr(0x00) .
		chr(length($Buffer)) . chr($STUN_ID); # STUN Header.
	my $Data = $STUN_Header . $Buffer;
	if ($STUN_Connected) {
		#$STUN_Sel->can_write(0.0001);
		if ($HDLC_Verbose >= 1) {Bytes_2_HexString($Data);}
		$STUN_ClientSocket->send($Data);
		if ($STUN_Verbose) {print "STUN_Tx sent.\n";}
	}
}



##################################################################
# MMDVM ##########################################################
##################################################################
sub WritePoll{
	my ($TalkGroup) = @_;
	my $Filler = chr(0x20);
	my $Data = chr(0xF0) . $Callsign;
	for (my $x = length($Data); $x < 11; $x++) {
		$Data = $Data . $Filler;
	}
	$TG{$TalkGroup}{'Sock'}->send($Data);
	if ($MMDVM_Verbose) {
		print "WritePoll IP " . $TG{$TalkGroup}{'MMDVM_TalkGroup'} .
			$TG{$TalkGroup}{'MMDVM_URL'} .
			" Port " . $TG{$TalkGroup}{'MMDVM_Port'} . "\n";
	}
		$TG{$TalkGroup}{'MMDVM_Connected'} = 1;
}

sub WriteUnlink{
	my ($TalkGroup) = @_;
	my $Filler = chr(0x20);
	my $Data = chr(0xF1) . $Callsign;
	for (my $x = length($Data); $x < 11; $x++) {
		$Data = $Data . $Filler;
	}
	$TG{$TalkGroup}{'Sock'}->send($Data);
	if ($MMDVM_Verbose) {
		print "WriteUnlink TG " . $TalkGroup .
			" IP " . $TG{$TalkGroup}{'MMDVM_URL'} .
			" Port " . $TG{$TalkGroup}{'MMDVM_Port'} . "\n";
	}
	$TG{$TalkGroup}{'MMDVM_Connected'} = 0;
	$TG{$TalkGroup}{'Sock'}->close();
}

sub MMDVM_Rx{ # Only HDLC UI Frame. Start on Quantar v.24 Byte 3.
	my ($TalkGroup, $Buffer) = @_;
	my $HexData = "";
	#if ($MMDVM_Verbose) {print "MMDVM_Rx Len(Buffer) = " . length($Buffer) . "\n";}
	if (length($Buffer) < 1) {return;}
	my $OpCode = ord(substr($Buffer, 0, 1));
	if ($MMDVM_Verbose) {print "MMDVM_Rx OpCode = " . sprintf("0x%X", $OpCode) . "\n";}
	switch ($OpCode) {
		case [0x62..0x73] { # Audio data.
			MMDVM_to_HDLC($Buffer); # Use to bridge MMDVM to HDLC.
		}
		case 0x80 { # End Tx.
			if ($MMDVM_Verbose) {print "  End Tx, TG $TalkGroup.\n";}
			MMDVM_to_HDLC($Buffer); # Use to bridge MMDVM to HDLC.
		}
		case 0xF0 { # Ref. Poll Ack.
			if ($MMDVM_Verbose) {print "  Poll Reflector Ack, TG $TalkGroup.\n";}
			#$MMDVM_Connected = 1;
		}	
		case 0xF1 { # Ref. Disconnect Ack.
			if ($MMDVM_Verbose) {print "  Ref. Disconnect Ack Rx, TG $TalkGroup.\n";}
			$TG{$TalkGroup}{'MMDVM_Connected'} = 0;
			$TG{$TalkGroup}{'Sock'}->close();
			#$MMDVM_Listen_Enable = 0;
		}
		case 0xF2 { # Start of Tx.
			if ($MMDVM_Verbose) {print "  0xF2, TG $TalkGroup.\n";}
		} else {
			print "  else " . hex(ord(substr($Buffer, 0, 1))) ." else Len = " . length($Buffer) . "\n";
		}
	}
}

sub MMDVM_Tx{
	my ($TalkGroup, $Buffer) = @_;
	$TG{$TalkGroup}{'Sock'}->send($Buffer);
}

##################################################################
# P25NX ##########################################################
##################################################################
sub P25NX_Disconnect{
	my ($TalkGroup) = @_;
	if ($TalkGroup > 10099 and $TalkGroup < 10600){
		my $MulticastAddress = makeMulticastAddress($TalkGroup);
		$TG{$TalkGroup}{'Sock'}->mcast_drop($MulticastAddress);
	}
	$TG{$TalkGroup}{'P25NX_Connected'} = 0;
	$TG{$TalkGroup}{'Sock'}->close();
	print "P25NX TG " . $TalkGroup . " disconnected.\n";
}

sub makeMulticastAddress{
	my ($TalkGroup) = @_;
	my $x = $TalkGroup - 10099;
	my $b = 0;
	my $c = 0;
	my $i;
	my $Region;
	my $ThisAddress;
	for ($i = 1; $i < 1000; $i++) {
		if ($x < 254) {
			$c = $x;
		} else {
			$x = $x - 254;
			$b = $b + 1;
		}
	}
	$Region = substr($TalkGroup, 2, 1);
	$ThisAddress = "239." . $Region . "." . $b . "." . $c;
	#if ($Verbose) {print "makeMulticastAddress = " . $ThisAddress . "\n";}
	return $ThisAddress;
}

sub P25NX_Rx{
	my ($Buffer) = @_;
	if (length($Buffer) < 1) {return;}
	#if ($Verbose) {print "PNX_Rx\n";} if ($Verbose) {
		#print "PNX_Rx HexData = " . StrToHex($Buffer) . "\n";
	#}
	#MMDVM_Tx(substr($Buffer, 9, length($Buffer)));
	P25NX_to_HDLC($Buffer);

}

sub P25NX_Tx{ # This function expect to Rx a formed Cisco STUN Packet.
	my ($Buffer) = @_;
	# Tx to the Network.
	if ($P25NX_Verbose >= 2) {print "P25NX_Tx Message " . StrToHex($Buffer) . "\n";}
	my $MulticastAddress = makeMulticastAddress($LinkedTalkGroup);
	my $Tx_Sock = IO::Socket::Multicast->new(
		LocalHost => $MulticastAddress,
		LocalPort => $P25NX_Port,
		Proto => 'udp',
		Blocking => 0,
		Broadcast => 1,
		ReuseAddr => 1,
		PeerPort => $P25NX_Port
		)
		or die "Can not create Multicast : $@\n";
	$Tx_Sock->mcast_ttl(10);
	$Tx_Sock->mcast_loopback(0);
	$Tx_Sock->mcast_send($Buffer, $MulticastAddress . ":" . $P25NX_Port);
	$Tx_Sock->close;
	if ($P25NX_Verbose) {
		print "P25NX_Tx TG " . $LinkedTalkGroup . " IP Mcast " . $MulticastAddress . "\n";
	}
	if ($P25NX_Verbose) {print "P25NX_Tx Done.\n";}
}

sub StrToHex{
	my ($Data) = @_;
	my $x;
	my $HexData = "";
	for ($x = 0; $x < length($Data); $x++) {
		$HexData = $HexData . " " . sprintf("0x%X", ord(substr($Data, $x, 1)));
	}
	print $HexData . "\n";
}



##################################################################
# P25Link ########################################################
##################################################################

sub P25Link_Disconnect {
	my ($TalkGroup) = @_;
	$TG{$TalkGroup}{'P25Link_Connected'} = 0;
	$TG{$TalkGroup}{'Sock'}->close();
}



##################################################################
# Traffic control ################################################
##################################################################
sub Tx_to_Network{
	my ($Buffer) = @_;
	Start_TG_Mute();
	if ( $MMDVM_Enabled and ((($LinkedTalkGroup > 11 and $LinkedTalkGroup < 10100)
		or ($LinkedTalkGroup > 10599 and $LinkedTalkGroup < 65535))
		or (!$P25NX_Enabled and !$P25Link_Enabled
			and ($LinkedTalkGroup >= 10100 and $LinkedTalkGroup < 10600))) ) { # Case MMDVM.
		HDLC_to_MMDVM($LinkedTalkGroup, $Buffer);
	}
	if ($P25NX_Enabled and ($LinkedTalkGroup >= 10100 and $LinkedTalkGroup < 10600)) { # case P25NX.
		HDLC_to_P25NX($Buffer);
	}
	if ($P25Link_Enabled and ($LinkedTalkGroup >= 10100 and $LinkedTalkGroup < 10600)) {
		HDLC_to_P25Link($Buffer);
	}
}

sub HDLC_to_MMDVM{
	my ($TalkGroup, $Buffer) = @_;
	switch (ord(substr($Buffer, 2 , 1))) {
		case 0x00 {
			switch  (ord(substr($Buffer, 6, 1))) {
				case 0x0C {
					MMDVM_Tx($TalkGroup, chr(0x72) . chr(0x7B) . 
						chr(0x3D) . chr(0x9E) . chr(0x44) . chr(0x00)
					);
				}
				case 0x25 {
					MMDVM_Tx($TalkGroup, chr(0x80) . chr(0x00). chr(0x00) .
						chr(0x00) . chr(0x00) . chr(0x00) . chr(0x00) .
						chr(0x00) . chr(0x00) . chr(0x00) . chr(0x00) .
						chr(0x00) . chr(0x00) . chr(0x00) . chr(0x00) .
						chr(0x00)
					);
				}
			}
		}
		case [0x62..0x73] {
			$Buffer = substr($Buffer, 2, length($Buffer)); # Here we remove first 2 Quantar Bytes.
			if ($Verbose) {print "HDLC_to_MMDVM output:\n";}
			if ($Verbose == 2) {Bytes_2_HexString($Buffer);}
			MMDVM_Tx($TalkGroup, $Buffer);
		}
		else {
			print "HDLC_to_MMDVM Error code " . hex(ord(substr($Buffer, 2, 1))) . "\n";
			Bytes_2_HexString($Buffer);
			return;
		}	
	}
}

sub HDLC_to_P25NX{
	my ($Buffer) = @_;
	my $Stun_Header = chr(0x08) . chr(0x31) . chr(0x00) . chr(0x00) . chr(0x00) .
		chr(2 + length($Buffer)) . chr($STUN_ID); #STUN Header.
	$Buffer = $Stun_Header . $Buffer;
	#print "HDLC_to_P25NX.\n";
	P25NX_Tx($Buffer);
}

sub MMDVM_to_HDLC{
	my ($Buffer) = @_;
	if ($HDLC_Handshake == 0 or length($Buffer) < 1) {return;}
	if ($MMDVM_Verbose == 2) {
		print "MMDVM_to_HDLC In.\n";
		Bytes_2_HexString($Buffer);
	}
	my $Address = 0xFD; #0x07 or 0xFD
	$Tx_Started = 1;
	my $OpCode = ord(substr($Buffer, 0, 1));
	switch ($OpCode) {
		case [0x62..0x73] { # Use to bridge MMDVM to HDLC.
			$Buffer = chr($Address) . chr($C_UI) . $Buffer;
			if ($MMDVM_Verbose == 2) {
				print "MMDVM_to_HDLC Out:\n";
				Bytes_2_HexString($Buffer);
			}
			$HDLC_TxTraffic = 1;
			HDLC_Tx($Buffer);
		}
		case 0x80 {
			$Tx_Started = 0;
			my $RTRT;
			if ($HDLC_RTRT_Enabled == 1) {
				$RTRT = $C_RTRT_Enabled;
			} else {
				$RTRT = $C_RTRT_Disabled;
			}
			HDLC_Tx(chr($Address) . chr($C_UI) . chr(0x00) . chr(0x02). chr($RTRT) .
				chr($C_EndTx) . chr($C_DVoice) . chr(0x00) . chr(0x00) . chr(0x00) .
				chr(0x00) . chr(0x00));
			HDLC_Tx(chr($Address) . chr($C_UI) . chr(0x00) . chr(0x02). chr($RTRT) .
				chr($C_EndTx) . chr($C_DVoice) . chr(0x00) . chr(0x00) . chr(0x00) .
				chr(0x00) . chr(0x00));
			$HDLC_TxTraffic = 0;
		}
	}
}

sub P25NX_to_HDLC{ # P25NX packet contains Cisco STUN and Quantar packet.
	my ($Buffer) = @_;
	$Buffer = substr($Buffer, 7, length($Buffer)); # Here we remove Cisco STUN.
	$HDLC_TxTraffic = 1;
	HDLC_Tx($Buffer);
# Add a 1s timer to $HDLC_TxTraffic = 0;
}


##################################################################
sub AddLinkTG{
	my ($TalkGroup) = @_;	
	if ($TG{$TalkGroup}{'Linked'} == 1 ) {
		return;
	}
	print "AddLinkTG " . $TalkGroup . "\n";

	# Now connect to a network.
	if ( $MMDVM_Enabled
		and ($TalkGroup > 10 and $TalkGroup < 10100) # MMDVM.
		or (!$P25NX_Enabled and ($TalkGroup >= 10100 and $TalkGroup < 10600)) # MMDVM P25NX Ref. 
		or ($TalkGroup >= 10600 and $TalkGroup < 65535)) { # MMDVM.

		# Connect to TG.
		if ($Verbose) {print "  MMDVM Connecting to TG " . $TG{$TalkGroup}{'MMDVM_TalkGroup'} .
			" IP " . $TG{$TalkGroup}{'MMDVM_URL'} .
			" on Port " . $TG{$TalkGroup}{'MMDVM_Port'} . "\n";
		}
		$TG{$TalkGroup}{Sock} = IO::Socket::INET->new(
			LocalPort => $MMDVM_LocalPort,
			Proto => 'udp',
			Blocking => 0,
			Broadcast => 0,
			ReuseAddr => 1,
			PeerHost => $TG{$TalkGroup}{'MMDVM_URL'},
			PeerPort => $TG{$TalkGroup}{'MMDVM_Port'}
		) or die "Can not Bind MMDVM : $@\n";
		$TG{$TalkGroup}{'Sel'} = IO::Select->new($TG{$TalkGroup}{'Sock'});
print "gagaga " . $TalkGroup ."\n";
		WritePoll($TG{$TalkGroup}{'MMDVM_TalkGroup'});

		WritePoll($TG{$TalkGroup}{'MMDVM_TalkGroup'});
		WritePoll($TG{$TalkGroup}{'MMDVM_TalkGroup'});
	}
	if ($P25NX_Enabled and $TalkGroup >= 10100 and $TalkGroup < 10600) { # case P25NX.
		my $MulticastAddress = makeMulticastAddress($TalkGroup);
		if ($Verbose) {print "  P25NX Connecting to " . $TalkGroup .
			" Multicast Addr. " . $MulticastAddress . "\n";
		}
			$TG{$TalkGroup}{Sock} = IO::Socket::Multicast->new(
			LocalHost => $MulticastAddress,
			LocalPort => $P25NX_Port,
			Proto => 'udp',
			Blocking => 0,
			Broadcast => 1,
			ReuseAddr => 1,
			PeerPort => $P25NX_Port
			)
			or die "Can not create Multicast : $@\n";
		$TG{$TalkGroup}{'Sel'} = IO::Select->new($TG{$TalkGroup}{'Sock'});
		$TG{$TalkGroup}{'Sock'}->mcast_add($MulticastAddress);
		$TG{$TalkGroup}{'Sock'}->mcast_ttl(10);
		$TG{$TalkGroup}{'Sock'}->mcast_loopback(0);
		$TG{$TalkGroup}{'P25NX_Connected'} = 1;
	}

	if ($P25Link_Enabled and $TalkGroup >= 10100 and $TalkGroup < 10600) { # case P25Link.

		$TG{$TalkGroup}{'P25Link_Connected'} = 1;
	}
	
	# Finalize link.
	$TG{$TalkGroup}{'Linked'} = 1;
	$LinkedTalkGroup = $TalkGroup;
	Start_TG_Mute();
	if ($TG{$TalkGroup}{'Scan'} == 0) {
		$TG{$TalkGroup}{'Timer'} = time();
	}
	if ($UseVoicePrompts) {
		$VA_Message = $TalkGroup; # Linked TalkGroup.
		$Pending_VA = 1;
	}
	print "  System Linked to TG " . $TalkGroup . "\n";
}


##################################################################
sub RemoveLinkTG {
	my ($TalkGroup) = @_;
	if ($TG{$TalkGroup}{'Linked'} == 0 ) {
		return;
	}
	print "RemoveLinkTG " . $TalkGroup . "\n";

	# Disconnect from current network.
	if ($TG{$TalkGroup}{'MMDVM_Connected'}) {
		WriteUnlink($TalkGroup);
		WriteUnlink($TalkGroup);
		WriteUnlink($TalkGroup);
	}
	if ($TG{$TalkGroup}{'P25NX_Connected'}) {
		P25NX_Disconnect($TalkGroup);
	}
	if ($TG{$TalkGroup}{'P25Link_Connected'}) {
		P25Link_Disconnect($TalkGroup);
	}
	$TG{$TalkGroup}{'Linked'} = 0;
	#if ($UseVoicePrompts) {
	#	$VA_Message = $TalkGroup; # Linked TalkGroup.
	#	$Pending_VA = 1;
	#}
	print "  System Disconnected from TG " . $TalkGroup . "\n";
}

sub Start_TG_Mute{
	$PriorityTGActive = 1;
	$MuteTGTimer = time() + $MuteTGTimeout;
}



#################################################################################
# Voice Announce ################################################################
#################################################################################
sub SaySomething{
	my ($ThingToSay) = @_;
	my @Speech;
	print "Voice Announcement running.\n";
	$HDLC_TxTraffic = 1;
	switch ($ThingToSay) {
		case 0x00 {
			@Speech = @Speech_SystemStart;
		}
		case 0x01 {
			@Speech = @Speech_DefaultRevert;
		}
		case 0x02 {
			@Speech = @HDLC_TestPattern;
		}
		case 10100 {
			@Speech = @Speech_WW;
		}
		case 10101 {
			@Speech = @Speech_WWTac1;
		}
		case 10102 {
			@Speech = @Speech_WWTac2;
		}
		case 10103 {
			@Speech = @Speech_WWTac3;
		}
		case 10200 {
			@Speech = @Speech_NA;
		}
		case 10201 {
			@Speech = @Speech_NATac1;
		}
		case 10202 {
			@Speech = @Speech_NATac2;
		}
		case 10203 {
			@Speech = @Speech_NATac3;
		}
		case 10300 {
			@Speech = @Speech_Europe;
		}
		case 10301 {
			@Speech = @Speech_EuTac1;
		}
		case 10302 {
			@Speech = @Speech_EuTac2;
		}
		case 10303 {
			@Speech = @Speech_EuTac3;
		}
		case 10310 {
			@Speech = @Speech_France;
		}
		case 10320 {
			@Speech = @Speech_Germany;
		}
		case 10400 {
			@Speech = @Speech_Pacific;
		}
		case 10401 {
			@Speech = @Speech_PacTac1;
		}
		case 10402 {
			@Speech = @Speech_PacTac2;
		}
		case 10403 {
			@Speech = @Speech_PacTac3;
		}
	}
	for (my $x = 0; $x < scalar(@Speech); $x++) {
		$Message = HexString_2_Bytes($Speech[$x]);
		HDLC_Tx($Message);
		my $SerialWait = (8.0 / 9600.0) * 1; # 1 Byte length delay for VA.
		nanosleep($SerialWait * 1000000000);
	}
	$HDLC_TxTraffic = 0;
	print "  Voice Announcement done.\n";
}

sub HexString_2_Bytes{
	my ($Buffer) = @_;
	my $Data;
	for (my $x = 0; $x < length($Buffer); $x = $x + 6) {
		#print "Dat = " . substr($Buffer, $x, 4) . "\n";
		#print "Dat2 = " . sprintf("%d", hex(substr($Buffer, $x, 4))) . "\n";
		$Data = $Data . chr(sprintf("%d", hex(substr($Buffer, $x, 4))));
	}
	#print "Data Length =" . length($Data) . "\n";
	#Bytes_2_HexString($Data);
	return $Data;
}



#################################################################################
# Misc Subs #####################################################################
#################################################################################
sub getTickCount {
	my ($epochSecs, $epochUSecs) = Time::HiRes::gettimeofday();
	#print $Epock secs $epochSecs Epoch usec $epochUSecs.\n";
	my $TickCount = ($epochSecs * 1000 + int($epochUSecs / 1000));
	return $TickCount;
}


sub Pin5_Interrupt_Handler {
    print "Pin5 Interrupt Handler.\n";
}



#################################################################################
# Main Loop #####################################################################
#################################################################################
sub MainLoop{
	while ($Run) {
		my $Scan = 0;
		my $TickCount = getTickCount();
		(my $sec, my $min, my $hour, my $mday, my $mon, my $year, my $wday, my $yday, my $isdst) = localtime();
		# HDLC Receive Ready keep alive.
		my $RR_Timeout = $RR_NextTimer - time();
		if ($RR_Timer = 1 && $RR_Timeout <= 0 and $HDLC_Handshake) {
			print $hour . ":" . $min . ":" . $sec . " Send RR by timer.\n"; 
			warn "RR Timed out @{[int time - $^T]}\n";
			if (($Mode == 1 and $STUN_Connected and $HDLC_TxTraffic == 0)
				or ($Mode == 0 and $HDLC_TxTraffic == 0)) {
				HDLC_Tx_RR();
				print "----------------------------------------------------------------------\n";
			}
			$RR_NextTimer = $RR_TimerInterval + time();
		}
		# Serial Port Receiver.
		if ($Mode == 0) {
			Read_Serial();
		}

		# Cisco STUN TCP Receiver.
		if (($Mode == 1) and ($STUN_Connected == 1)) {
			for $STUN_fh ($STUN_Sel->can_read(0.0001)) {
				my $RemoteHost = $STUN_fh->recv(my $Buffer, $MaxLen);
				if ($RemoteHost) {
					print "RemoteHost = " . $RemoteHost . "\n";
					die;
				}
				if (length($Buffer) > 7) {
					#my $RemoteHost = $STUN_ClientSocket->recv(my $Buffer, $MaxLen);
					if ($STUN_Verbose) {
						print $hour . ":" . $min . ":" . $sec .
						" " . $RemoteHost . 
						" STUN Rx Buffer len(" . length($Buffer) . ")\n";
					}
					HDLC_Rx(substr($Buffer, 7, length($Buffer)), 0);
				}
			}
		}




		# MMDVM WritePoll beacon.
		my $MMDVM_Timeout = $MMDVM_Poll_NextTimer - time();
		#if ($Verbose) {print "Countdown to send WritePoll = " . $MMDVM_Timeout . "\n";}
		if ($MMDVM_Timeout <= 0) {
			#print $hour . ":" . $min . ":" . $sec . " Sending WritePoll beacon.\n";
			#warn "MMDVM_Poll Timed out @{[int time - $^T]}\n";
			foreach my $key (keys %TG) {
				if ($TG{$key}{'MMDVM_Connected'}) {
					WritePoll($TG{$key}{'MMDVM_TalkGroup'});
				}
			}
			$MMDVM_Poll_NextTimer = $MMDVM_Poll_Timer_Interval + time();
		}
		# MMDVM Receiver.
		foreach my $key (keys %TG) {
			if ($TG{$key}{'MMDVM_Connected'}) {
				for my $MMDVM_fh ($TG{$key}{Sel}->can_read(0.0001)) {
					$MMDVM_RemoteHost = $MMDVM_fh->recv(my $Buffer, $MaxLen);
					$MMDVM_RemoteHost = $MMDVM_fh->peerhost;
					if ($MMDVM_Verbose) {print "MMDVM_RemoteHost = " . $MMDVM_RemoteHost . "\n";}
					if (($MMDVM_RemoteHost cmp $MMDVM_LocalHost) != 0) {
						#if ($Verbose) {print $hour . ":" . $min . ":" . $sec .
						#	" " . $MMDVM_RemoteHost .
						#	" MMDVM Data len(" . length($Buffer) . ")\n";}
						MMDVM_Rx($key, $Buffer);
					}
				}
			}
		}
		# P25NX Receiver
		foreach my $key (keys %TG) {
			if ($TG{$key}{'P25NX_Connected'}) {
				my $TalkGroup;
				my $OutBuffer;
				for my $P25NX_fh ($TG{$key}{Sel}->can_read(0.0001)) {
					my $P25NX_RemoteHost = $P25NX_fh->recv(my $Buffer, $MaxLen);
					$P25NX_RemoteHost = $P25NX_fh->peerhost;
					#if ($Verbose) {print "P25NX_LocalHost = " . $PNX_LocalHost . "\n";}
					my $MulticastAddress = makeMulticastAddress($TG{$key}{'P25NX_TalkGroup'});
					if (($P25NX_RemoteHost cmp $MulticastAddress) != 0) {
						if ($P25NX_Verbose) {print $hour . ":" . $min . ":" . $sec .
							" " . $P25NX_RemoteHost .
							" P25NX Data len(" . length($Buffer) . ")\n";
						}
						if (!$PriorityTGActive and ($TG{$key}{'Scan'} > $Scan)) {
							$TalkGroup = $key;
							$OutBuffer = $Buffer;
							$Scan = $TG{$key}{'Scan'};
						}
						if ($key == $LinkedTalkGroup) {
							$TalkGroup = $key;
							$OutBuffer = $Buffer;
							Start_TG_Mute();
							last;
						}
					}	
				}
				if ($TalkGroup) {
					P25NX_Rx($OutBuffer);
				}
			}
		}
		# P25Link Receiver
		foreach my $key (keys %TG) {
			if ($TG{$key}{'P25Link_Connected'}) {
				
			}
		}

		# Mute non priority TGs timer.
		if ($PriorityTGActive and ($MuteTGTimer  <=  time())) {
			print "$PriorityTGActive Mute Timeout End.\n";
			$PriorityTGActive = 0;
		}


		# End of Tx timmer (1 sec).
		if ($Quant{0}{'LocalRx'} and ($Quant{0}{'LocalRx_Time'} + 1000 >= $TickCount)) {
			$Quant{0}{'LocalRx'} = 0;
		}


		# Voice Announce.
		if ($HDLC_Handshake and ($Quant{0}{'LocalRx'} == 0) and $Pending_VA) {
			SaySomething($VA_Message);
			$Pending_VA = 0;
		}


		# Hot Keys.
		if ($HotKeys) {
			if (not defined (my $key = ReadKey(-1))) {
				# No key yet.
			} else {
				switch (ord($key)) {
					case 0x1B { # Escape
						print "EscKey Pressed.\n";
						$Run = 0;
					}
					case ord('C') { # 'C'
						$STUN_Verbose = 1;
					}
					case ord('c') { # 'c'
						$STUN_Verbose = 0;
					}
					case ord('H') { # 'H'
						$HDLC_Verbose = 1;
					}
					case ord('h') { # 'h'
						PrintMenu();
						$HDLC_Verbose = 0;
					}
					case ord('L') { # 'L'
						$P25Link_Verbose = 1;
					}
					case ord('l') { # 'l'
						$P25Link_Verbose = 0;
					}
					case ord('M') { # 'M'
						$MMDVM_Verbose = 1;
					}
					case ord('m') { # 'm'
						$MMDVM_Verbose = 0;
					}
					case ord('P') { # 'P'
						$P25NX_Verbose = 1;
					}
					case ord('p') { # 'p'
						$P25NX_Verbose = 0;
					}
					case ord('Q') { # 'Q'
						$Run = 0;
					}
					case ord('q') { # 'q'
						$Run = 0;
					}
						case 0x41 { # 'UpKey'
						print "UpKey Pressed.\n";
					}
					case 0x42 { # 'DownKey'
						print "DownKey Pressed.\n";
					}
					case 0x43 { # 'RightKey'
						print "RightKey Pressed.\n";
					}
					case 0x44 { # 'LeftKey'
						print "LeftKey Pressed.\n";
					}
					case '[' { # '['
						print "[ Pressed (used also as an escape char).\n";
					}
					else {
						if ($Verbose) {
							print sprintf(" %x", ord($key));
							print " Key Pressed\n";
						}
					}
				}
			}
		}
		if ($Verbose >= 5) {print "Looping the right way.\n";}
		#my $NumberOfTalkGroups = scalar keys %TG;
		#print "Total number of links is: " . $NumberOfTalkGroups . "\n\n";



	}
}
