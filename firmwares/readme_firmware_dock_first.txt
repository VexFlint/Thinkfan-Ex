                                                                   Revision : 10
--------------------------------------------------------------------------------
Package Name       ThinkPad USB-C Dock FW update tool

--------------------------------------------------------------------------------
Operating Systems	Microsoft Windows 7 64-bits
		Microsoft Windows 10 64-bit (1809 or later)
		Microsoft Windows 11 64-bit (21H2 or later)

		Refer to marketing materials to find out what computer
		models support which Operating Systems.

Firmware Version   V3.7.04

Format             Executable file

--------------------------------------------------------------------------------
WHAT THIS PACKAGE DOES

This utility will update the ThinkPad USB-C dock Firmware

This package is compiled into an executable file which runs on Microsoft Windows 7, Windows 10 and Windows 11
--------------------------------------------------------------------------------
IMPORTANT INFORMATION

"IMPORTANT: DO NOT terminate update process with power off, undock or plug out an"
           external display monitor.  Or your docking station may need to be replaced.
--------------------------------------------------------------------------------
CHANGES IN THIS RELEASE

Firmware Version   3.7.04

- Audio: 04-0E-99
- BB: 0.1.0.23
- USB Hub: 1.14.7.183
- PD Control: 1.3.40
- DP Hub: 3.13.005
--------------------------------------------------------------------------------
LIMITATION
N/A

--------------------------------------------------------------------------------
INSTALLATION INSTRUCTIONS

Manual Install

  This section assumes to use Microsoft Edge and Windows Explorer.

  Download Docking FW Package
  1. Select the underlined file name. Once this is done, some pop-up windows
     will appear.
  2. Follow the instructions on the screen.
  3. In the window to choose "Extract Only" or "Install", select "Extract Only".
  4. Choose the folder you would like to download the file to, and select Extact.
     A different window will appear and the download will begin and complete.
     Once the download has completed, there may or may not be a message stating
     that the download completed successfully.
  5. Make sure to be logged on with an administrator account.
  6. Make sure your Dock connect to system.
  Upgrade Docking FW
  1. Close all applications.
  2. Double click the downloaded executable file.
  3. It will show both installed and going to be installed firmware versions.
  4. Click next button, if your docking station has older than this FW package
  5. Follow the instructions on the screen to complete installation
  6. If your docking station already updated, click Cancel update button to exit.

  Finally delete the file saved in the step 4.

   -- Silent Installation by command in SCCM deploy:
       1. Connect dock to PC/NB;
       2. [File Located folder]\usbcdkfw*.exe /VERYSILENT /s
       3. Return code / Result list
          0 : Update FW successfully.
          1 : Current FW is newer or the same, no need to update.
         -1 : Can't check FW version, device not found or other errors.
         -2 : Update DP Hub FW version failed.
         -3 : Update Billboard FW version failed.
         -4 : Update CCG4/HX3 version failed.
         -5 : Update Audio FW version failed.

    -- FW version check by command in SCCM deploy:
       1. Connect dock to PC/NB;
       2. [File Located folder]\usbcdkfw*.exe /VERYSILENT /v
       3. FW version information will be showed in the log file "update.log".
       4. Return code / Result list
          0 : Read version successfully, current FW is newer or the same.
          1 : Read version successfully, current FW is older.
         -1 : Can't check FW version, device not found or other errors.
       -102 : Check DP Hub FW version failed.
       -103 : Check Billboard FW version failed.
       -104 : Check CCG4/HX3 version failed.
       -105 : Check Audio FW version failed.

    -- Command for silent deployment in other environment:
       1>. Extract the file to a local directory with command:
           usbcdkfw*.exe /VERYSILENT /EXTRACT="YES" /DIR="c:\usbc-dock"
       2>. Enter the directory: cd usbc-dock
       3>. Execture the command with parameters:
           Update FW command with silent   : usbc_cmd.exe /u /s
           Update FW command without silent: usbc_cmd.exe /u
           Return code / Result list
            0 : Update FW successfully.
            1 : Current FW is newer or the same, no need to update.
           -1 : Can't check FW version, device not found or other errors.
           -2 : Update DP Hub FW version failed.
           -3 : Update Billboard FW version failed.
           -4 : Update CCG4/HX3 version failed.
           -5 : Update Audio FW version failed.
        4>. Check version
           usbc_cmd.exe /v
           Return code / Result list
             0 : Read version successfully, current FW is newer or the same.
             1 : Read version successfully, current FW is older.
            -1 : Can't check FW version, device not found or other errors.
          -102 : Check DP Hub FW version failed.
          -103 : Check Billboard FW version failed.
          -104 : Check CCG4/HX3 version failed.
          -105 : Check Audio FW version failed.


--------------------------------------------------------------------------------
VERSION INFORMATION

package                            version         rev      date
--------------------------------------------------------------------------------
usbcdkfw3704_2 	  	3.7.04   	10    2023-04-04
usbcdkfw3704_1 	  	3.7.04   	09    2021-10-25
fusbcd08   			3.7.4   	08    2021-06-25
fusbcd07   			3.7.3   	07    2020-07-27
fusbcd06   			3.7.3   	06    2020-01-20
fusbcd05   			3.7.3   	05    2019-08-26
fusbcd01   			3.7.0   	01    2018-04-19

  Note: Revision number (Rev.) is for administrative purpose of this README
        document and is not related to software version. There is no need to
        upgrade this software when the revision number changes.

Summary of Changes

  Where: <   >        Package version number
         [Important]  Important update
         (New)        New function or enhancement
         (Fix)        Correction to existing function

<usbcdkfw3704_2> 3.7.04
        Audio:04-0E-99
	BB:0.1.0.23
	USB Hub:1.14.7.183
	PD Control:1.3.40
	DP Hub:3.13.005

	<New>
	1. Update DP utility to fix some notebooks detect or update DP FW error.

<usbcdkfw3704_1> 3.7.04
        Audio:04-0E-99
	BB:0.1.0.23
	USB Hub:1.14.7.183
	PD Control:1.3.40
	DP Hub:3.13.005

	<New>
	1. Add a silent update for Dock Manager.
	2. Change Version from "3.7.4" to "3.7.04".
	3. Follow new name rule to change package name to "usbcdkfw3704_tvsu9".


<fusbcd08> 3.7.4
        Audio:04-0E-99
	BB:0.1.0.23
	USB Hub:1.14.7.183
	PD Control:1.3.40
	DP Hub:3.13.005

	<New>
	To fix L13 Yoga Gen 2 no display issue with USB C dock Gen1 and T24i monitor.


<fusbcd07> 3.7.3
        Audio:04-0E-99
	BB:0.1.0.23
	USB Hub:1.14.7.183
	PD Control:1.3.40
	DP Hub:3.13.002

	<New>
	Add update parameter /ShowVer function for lenovo internal usage.


<fusbcd06> 3.7.3
        Audio:04-0E-99
	BB:0.1.0.23
	USB Hub:1.14.7.183
	PD Control:1.3.40
	DP Hub:3.13.002

	<Fix>
	Address security vulnerability issues CVE-2019-6173 and CVE-2019-6196.

<fusbcd05> 3.7.3
        Audio:04-0E-99
	BB:0.1.0.23
	USB Hub:1.14.7.183
	PD Control:1.3.40
	DP Hub:3.13.002


    Audio FW (Fix):
        [Ver04-0E-99]
        1. Fix jack detect not work after S3/S4/s5.
        2. Fix no audio after upgrade from certain version of FW.

        [Ver04-0E-98]
	1. Remove HID2 support to fix "System Screen lights on automatically after WOL from dock under S3".

        [Ver04-0E-97]
	1. Improve the pop noise when play/pause.

        [Ver04-0E-96]
        1. Change the USB configuration. Now the volume gain change is control by host. host didn't send SET_CUR to set gain.
        2. Add inline button Vol+/Vol-.

        [Ver04-0E-95]
        1. Change device type to headset.

        [Ver04-0E-94]
        1. Support jack status HID report and kernel mode jack sensing.
        2. Remove button event support.
        3. Set 1.2 regulators to Max at 1.375V.

        [Ver04-0E-93]
        1.Test code with updated VDD CORE from 1.17V to 1.26V.


    DP Hub (Fix):
        [Ver3.13.002]
	1. Fix the DP monitor keep flicking issue due to monitor keep reporting LIF.
	2. Add workaround for Vizio TV 2010 model to enable the audio on that TV.
	3. Change the 2560x1440 resolution HDMI output pull tuning mode to avoid random screen flashing after long time running.
	4. Fix the DP monitor sometimes no display issue at 10bpc output.
	4. Adding support to YCbCr4:2:2 mode 10/12 BPC HDMI output.

        [Ver3.13.001]
	1. Fix the regression issue that always start HDCP1.4 authentication with downstream TX at very beginning.
	2. Enhance the HDMI output error handling for RX SST input ViewXpand mode.

        [Ver3.13.000]
 	1. Fix the repeater HDCP failure issue when RX works in SST input mode.

        [Ver3.12.009]
	1. Revised from previous release.
	2. Disable the EFM mode only and only if downstream TX MST mode is enabled.

        [Ver3.12.009]
	1. Always retry if TX side HDCP authentication failed and RX side encryption is enabled.

        [Ver3.12.008]
	1. Remove the HDCP supporting if there is VGA monitor connected on the downstream TX side, to avoid some MAC system response slow down by failing HDCP Authentication.
	2. Filter out the YUV color space supporting to avoid abnormal color on VGA output with some MAC system.
	3. Report LIF to RX side if HDCP authentication failed with downstream monitor more than 5 times, to request the source redo the HDCP authentication.

        [Ver3.12.007]
	1. Filter out the HDMI2.0 support of downstream monitor EDID.
	2. Limit the maximal pixel clock to the maximal downstream bandwidth in the display range field of the EDID.
	3. Modify the REMOTE_EDID function to support WinOS on MacBook 2017 system.
	4. Forward LIF error to source side if downstream MST monitors report LIF error.
	5. Trigger the MST output again after allocates the PID to downstream MST monitor.

        [Ver3.12.006]
	1. Add support to long MST DOWN_REQ message which need send via multiple sideband message.



<fusbcd01> 3.7
- Initial release.
	BB:0.1.0.23
	USB Hub:1.14.7.183
	PD Control:1.3.40
	DP Hub:3.12.005

--------------------------------------------------------------------------------

Support models

	X13 AMD Gen 2(#20XH,20XJ)
	L13 Yoga AMD Gen2(#21AD,21AE)
	L13 Clam AMD Gen2(#21AB,21AC)
	T14s AMD Gen2(#20XF,20XG)
	T14 AMD Gen2(#20XK,20XL)

	Lenovo MIIX 520-12IKB(#20M3,20M4î“¤
	X1 Tablet Gen 2(#20JB,20JC)
	X13 Yoga Gen2(#20W8,20W9)
	X13 Gen 2(#20WK,20WL)
	X1 Yoga Gen 6(#20XY,20X0)
	X1 Carbon Gen 9(#20XW,20XX)
	X12 Detachable Gen 1(#20UW,20UV)
	X1 Titanium Yoga Gen 1(#20QA,20QB)
	X1 Nano Gen 1(#20UN,20UQ)
	X1 Extreme Gen 3(#20TL,20TK)
	X1 Yoga 5th Gen(#20UB,20UC)
	X1 Extreme Gen 2(#20QV,20QW)
	X1 Carbon 7th Gen(#20QD,20QE,20R1,20R2)
	X1 Yoga 4th Gen(#20QF,20QG,20SA,20SB)
	X390(#20Q0,20Q1,20SC,20SD)
	X1 Yoga 3rd Gen(#20LD,20LE,20LF,20LG)
	X1 Carbon 5th Gen(#20HQ,20HR,20K3,20K4)
	A285(#20MW,20MX)
	A485(#20MU,20MV)
	X380 Yoga(#20LH, 20LJ,20LK)
	L15 AMD Gen2(#20X7,20X8)
	L14 AMD Gen2(#20X5,20X6)
	L15 Gen2(#20X3,20X4)
	L14 Gen2(#20X1,20X2)
	L13 Clam G2(#20VH,20VJ)
	L13 Yoga G2(#20VK,20VL)

	T14s Gen2(#20WM,20WN)
	T14 Gen 2(HC)(#20W2,20W3)
	T14 Gen 2(#20W0,20W1)
	T15 Gen 2(#20W4,20W5)
	T15g Gen 1(#20UR,20US)
	T14 Gen 1(HC)(#20S2,20S3)
	ThinkPad 25(#20K7î“¤
	T570(#20H9,20HA,20JW,20JX)
	P14s AMD Gen 2(#21A0,21A1)
	P14s Gen 2(#20VX,20VY)
	P15s Gen 2(#20W6,20W7)
	P1 Gen 3(#20TH,20TJ)
	P15 Gen 1(#20ST,20SU)
	P17 Gen 1(#20SN,20SQ)
	P51s(#20HB,20HC,20JY,20K0)
	E15(#20RD,20RE)
	ThinkPad E15 Gen 2 (20TD,20TE)
	ThinkPad E14 Gen 2 (20TA,20TB)
	ThinkPad R14 Gen 2(20TC)
	ThinkPad P14s Gen 1(20Y1,20Y2)
	ThinkPad P15v Gen 1(20TQ, 20TR)
	ThinkPad T15p Gen 1(20TN, 20TM)
	ThinkPad X13 Gen1(20UF,20UG)
	ThinkPad T14 Gen1(20UD,20UE)
	ThinkPad T14s Gen1(20UH,20UJ)
	ThinkPad E15 Gen 2(20T8,20T9)
	ThinkPad E14 Gen 2(20T6,20T7)
	ThinkPad L14 Gen 1(20U5, 20U6)
	ThinkPad L15 Gen 1(20U7,20U8)
	ThinkPad P73(20QR,20QS)
	ThinkPad P53(20QN,20QQ)
	ThinkPad L15 Gen 1(20U3,20U4)
	ThinkPad L14 Gen 1(20U1,20U2)
	ThinkPad T14s Gen 1(20T0,20T1)
	ThinkPad P15s Gen 1(20T4,20T5)
	ThinkPad T15 Gen 1(20S6,20S7)
	ThinkPad P14s Gen 1(20S4,20S5)
	ThinkPad T14 Gen 1(20S0,20S1,20S2,20S3)
	ThinkPad X13 Gen 1(20T2,20T3)
	ThinkPad X13 Yoga Gen 1(20SX,20SY)
	ThinkPad X1 Yoga 5th Gen(20UB,20UC)
	ThinkPad X1 Carbon 8th Gen(20U9,20UA)
	ThinkPad11e Yoga Gen 6(20SE,20SF)
	ThinkPad L13(20R5,20R6)
	ThinkPad L13 Yoga(20R3,20R4)
	ThinkPad S2 Yoga 5th (20R8)
	ThinkPad S2 5th Gen(20R7)
	ThinkPad E14(20RA,20RB)
	ThinkPad R14(20RC)
	ThinkPad S3 Gen2(20RG)
	ThinkPad T490(20N2,20N3,20Q9,20QH)
	ThinkPad P43s(20RH,20RJ)
	ThinkPad T590(20N4,20N5)
	ThinkPad P53s(20N6,20N7)
	ThinkPad T490s(20NX,20NY)
	ThinkPad X390 Yoga (ROW)(20NN,20NQ)
	ThinkPad L390(20NR,20NS)
	ThinkPad L390 Yoga(20NT,20NU)
	ThinkPad S2 4th Gen(20NV)
	ThinkPad S2 Yoga 4th Gen(20NW)
	ThinkPad R490(20NA)
	ThinkPad E490(20N8,20N9)
	ThinkPad R590(20ND)
	ThinkPad E590(20NB,20NC)
	ThinkPad E490s(20NG,20QC)
	ThinkPad E495(20NE)
	ThinkPad E595(20NF)
	ThinkPad T495(20NJ,20NK)
	ThinkPad T495s(20QJ,20QK)
	ThinkPad X395(20NL,20NM)
	ThinkPad L590(20Q7,20Q8)
	ThinkPad L490(20Q5,20Q6)
	ThinkPad X280(20KE,20KF)
	ThinkPad T480s(20L7,20L8)
	ThinkPad T580(20L9,20LA)
	ThinkPad P52s(20LB,20LC)
	ThinkPad T480(20L5,20L6)
	ThinkPad X1 Carbon 6th(20KH,20KG)
	ThinkPad X1 Tablet Gen 3(20KJ,20KK)
	ThinkPad S1 4th Generation)(PRC)(20LL)
	ThinkPad L380(20M5,20M6)
	ThinkPad S2 3rd Gen(20L1)
	ThinkPad L380 Yoga(20M7,20M8)
	ThinkPad S2 Yoga 3rd Gen(20L2)
	ThinkPad Yoga 11e 5th Gen(20LM,20LN)
	ThinkPad 11e 5th Gen(20LQ,20LR)
	ThinkPad L580(20LW,20LX)
	ThinkPad L480(20LS,20LT)
	Lenovo Tablet 10(20L3,20L4)
	ThinkPad X1 Yoga 2nd(20JD,20JE,20JF,20JG)
	ThinkPad T470(20HD,20HE,20JM,20JN)
	ThinkPad A475(20KL,20KM)
	ThinkPad T470s(20HF,20HG,20JS,20JT)
	ThinkPad X270(20HM,20HN,20K5,20K6)
	ThinkPad A275(20KC,20KD)
	ThinkPad 13(20J1,20J2)
	ThinkPad S2(20J3)
	ThinkPad E570(20H5,20H6)
	ThinkPad P1 Gen 2(20QT,20QU)
	ThinkPad Yoga 370(20JH,20JJ)
	ThinkPad T490(20RX,20RY)

	ThinkPad USB-C Dock(40A9)
--------------------------------------------------------------------------------
TRADEMARKS

* Lenovo and ThinkPad are registered trademarks of Lenovo.

* Microsoft, Windows and Windows Vista are registered trademarks of Microsoft
  Corporation.

Other company, product, and service names may be registered trademarks,
trademarks or service marks of others.
