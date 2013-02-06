#!/bin/bash

declare -r myV="4.9a"
declare -r gccVersToUse="4.7.2" # failsafe check

# Reset locales (important when grepping strings from output commands)
export LC_ALL=C

# Retrieve full path of the command
declare -r CMD=$([[ $0 == /* ]] && echo "$0" || echo "${PWD}/${0#./}")

# Retrieve full path of CloverGrowerPro
declare -r CLOVER_GROWER_PRO_SCRIPT=$(readlink "$CMD" || echo "$CMD")
declare -r CLOVER_GROWER_PRO_DIR=${CLOVER_GROWER_PRO_SCRIPT%/*}
declare -r CLOVER_GROWER_PRO_CONF="$CLOVER_GROWER_PRO_DIR/CloverGrowerPro.conf"

# Source librarie
source "$CLOVER_GROWER_PRO_DIR/CloverGrowerPro.lib"

# Source config file
[[ ! -f "$CLOVER_GROWER_PRO_CONF" ]] && touch "$CLOVER_GROWER_PRO_CONF"
source "$CLOVER_GROWER_PRO_CONF"

target="X64"
if [ "$1" == "" ]; then
	target="X64/IA32"
fi

function checkConfig() {
    if [[ -z "$TOOLCHAIN" ]];then
        echo "Where to put the toolchain directory ?"
        TOOLCHAIN=$(prompt "TOOCHAIN directory" "$CLOVER_GROWER_PRO_DIR/toolchain")
        storeConfig 'TOOLCHAIN' "$TOOLCHAIN"
    fi
    if [[ -z "$EDK2DIR" ]];then
        echo "Where to put the edk2 source files ?"
        EDK2DIR=$(prompt "edk2 directory" "$CLOVER_GROWER_PRO_DIR/edk2")
        storeConfig 'EDK2DIR' "$EDK2DIR"
    fi
    if [[ -z "$CLOVERSVNURL" ]]; then
        local developper=$(prompt "Do you have the rights to commit Clover source files" "No")
        local login
        if [[ $(lc "$developper") == y* ]];then
            login=$(prompt "What is your login on sourceforge.net" "")
        fi
        if [[ -n "$login" ]];then
            CLOVERSVNURL="svn+ssh://$login@svn.code.sf.net/p/cloverefiboot/code"
        else
            CLOVERSVNURL='svn://svn.code.sf.net/p/cloverefiboot/code'
        fi
        storeConfig 'CLOVERSVNURL' "$CLOVERSVNURL"
    fi
	if [[ -z "$CLOVERLOCALREPO" ]];then
		local repotype=$(prompt "Do you want svn or git local clover repository" "svn")
		if [[ $(lc "$repotype") == g* ]];then
			CLOVERLOCALREPO='git'
		else
			CLOVERLOCALREPO='svn'
		fi
		storeConfig 'CLOVERLOCALREPO' "$CLOVERLOCALREPO"
	fi
}

checkConfig

# don't use -e
set -u

theBoss=$(id -ur)
hours=$(get_hours)

#vars
export WORKDIR="$CLOVER_GROWER_PRO_DIR"
export TOOLCHAIN="${CLOVER_GROWER_PRO_DIR}/toolchain"
workSpace=$(df -m "${WORKDIR}" | tail -n1 | awk '{ print $4 }')
workSpaceNeeded="522"
workSpaceMin="104"
filesDIR="${WORKDIR}"/Files
UserDIR="${WORKDIR}"/User/etc
etcDIR="${WORKDIR}"/Files/etc
srcDIR="${WORKDIR}"/src
CloverDIR="${EDK2DIR}"/Clover
rEFItDIR="${CloverDIR}"/rEFIt_UEFI
buildDIR="${EDK2DIR}"/Build
cloverPKGDIR="${CloverDIR}"/CloverPackage
builtPKGDIR="${WORKDIR}"/builtPKG
theBuiltVersion=""

# Some Flags
buildClover=0

[[ ! -d "${builtPKGDIR}" ]] && mkdir "${builtPKGDIR}"

style=release

if [[ ! -d "$EDK2DIR" && "$workSpace" -lt "$workSpaceNeeded" ]]; then
    echob "error!!! Not enough free space"
    echob "Need at least $workSpaceNeeded bytes free"
    echob "Only have $workSpace bytes"
    echob "move CloverGrower to different Folder"
    echob "OR free some space"
    exit 1
elif [[ "$workSpace" -lt "$workSpaceMin" ]]; then
    echob "Getting low on free space"
fi
workSpaceAvail="$workSpace"

#what system
theSystem=$(uname -r)
theSystem="${theSystem:0:2}"
case "${theSystem}" in
    [0-8]) sysmess="unsupported" ;;
    9) rootSystem="Leopard" ;;
    10) rootSystem="Snow Leopard" ;;
    11) rootSystem="Lion" ;;
    12) rootSystem="Mountain Lion" ;;
    [13-20]) sysmess="Unknown" ;;
esac

function checkCloverLink() {
    if [[ ! -L "/usr/local/bin/clover" || $(readlink "/usr/local/bin/clover") != "$CLOVER_GROWER_PRO_SCRIPT" ]]; then
        echob "Running CloverGrowerPro.sh"
        printf "Will create link %s to %s\n" $(echob "/usr/local/bin/clover") $(echob "CloverGrowerPro.sh")
        echob "You can THEN 'run' CloverGrowerPro.sh by typing 'clover' ;)"
        echob "Press Enter to continue"
        read
        if [ ! -d /usr/local/bin ]; then
            command="sudo mkdir -p /usr/local/bin"; echob "$command" ; eval $command
        fi
        command="sudo ln -sf $CLOVER_GROWER_PRO_SCRIPT /usr/local/bin/clover && sudo chown $theBoss /usr/local/bin/clover"
        echob "$command" ; eval $command
    fi
}

# Check XCode command line tools
function checkXCode() {
    if [[ ! -x /usr/bin/gcc ]]; then
        echob "ERROR:"
        echob "      Xcode Command Line Tools from Apple not found!"
        echob "      CloverGrowerPro.sh needs it";echo
        echob "      Going To Apple Developer Site"
        echob "      Download & Install XCode Command Line Tools then re-run CloverGrowerPro.sh"
        echo
        echob "      Press enter to open a browser to download XCode Command Line Tools"
        read
        open "https://developer.apple.com/downloads/"
        wait
        echob "Good $hours"
        tput bel
        exit 1
    fi
}

# Check Toolchain
function checkToolchain() {
    [[ -z "$TOOLCHAIN" ]] && echob "variable TOOLCHAIN not defined !" && exit 1
    if [[ ! -x "${TOOLCHAIN}/bin/x86_64-linux-gnu-gcc" ]]; then
        installToolchain
    fi
}

# Check Directories
function checkDirs() {
    for d in $cloverPKGDIR/CloverV2/EFI/drivers32 \
             $cloverPKGDIR/CloverV2/EFI/drivers64 \
             $cloverPKGDIR/CloverV2/EFI/drivers64UEFI ; do \
        [[ ! -d "$d" ]] && mkdir -p "$d"
    done
}

# Check the build environment
function checkEnv() {
    checkCloverLink
    checkXCode
    # Check for svn
    [[ -z $(type -P svn) ]] && { echob "svn command not found. Exiting..." >&2 ; exit 1; }
    checkToolchain
    checkDirs
}

# checkout/update svn
# $1=name $2=Local folder, $2=svn Remote url
# return code:
#     0: no update found
#     1: update found
function getSOURCEFILE() {
    local name="$1"
    local localdir="$2"
    local svnremoteurl="$3"
    local repotype="${4:-svn}"
    if [ ! -d "$localdir" ]; then
        echob "    ERROR:"
        echo  "        Local $localdir folder not found.."
        echob "        Making local ${localdir} folder..."
        mkdir "$localdir"
        echob "    Checking out Remote $name revision "$(getSvnRevision "$svnremoteurl")
        echo  "    svn co $svnremoteurl"
        checkout_repository "$localdir" "$svnremoteurl" "$repotype"
        return 1
    fi

    local localRev=$(getSvnRevision "$localdir")
    local remoteRev=$(getSvnRevision "$svnremoteurl")
    if [[ "${localRev}" == "${remoteRev}" ]]; then
        echob "    Checked $name SVN, 'No updates were found...'"
        return 0
    fi
    echob "    Checked $name SVN, 'Updates found...'"
    echob "    Auto Updating $name From $localRev to $remoteRev ..."
    tput bel
    update_repository "$localdir" "$repotype"
    checkit "    Svn up $name" "$svnremoteurl"
    return 1
}

# sets up svn sources
function getSOURCE() {
    if [ ! -d "${srcDIR}" ]; then
        echob "  Make src Folder.."
        mkdir "${srcDIR}"
    fi
    if [ ! -d "${EDK2DIR}"/Build/CloverX64 ] && [ ! -d "${EDK2DIR}"/Build/CloverIA32 ]; then
        buildMode=">CleanAll< Build  "
    fi
    if [ -d "${EDK2DIR}"/Build/CloverX64 ] || [  -d "${EDK2DIR}"/Build/CloverIA32 ]; then
        buildMode=">>>Clean<<< Build "
    fi

    # Don't update edk2 if no Clover updates
    if [[ "${cloverUpdate}" == "Yes" ]]; then
        # Get edk2 source
        cd "${srcDIR}"
        getSOURCEFILE edk2 "$EDK2DIR" "https://edk2.svn.sourceforge.net/svnroot/edk2/trunk/edk2"
        local buildBaseTools=$?

        # Is edk2 need to be update
        if [[ "$buildBaseTools" -eq 1 ]]; then
            cd "${EDK2DIR}"

            # Remove old edk2 config files
            rm -f "${EDK2DIR}"/Conf/{BuildEnv.sh,build_rule.txt,target.txt,tools_def.txt}

            # Create new default edk2 files in edk2/Conf
            ./edksetup.sh >/dev/null

            make -C BaseTools clean &>/dev/null
            # Basetool will be build automatically when Clover will be build
        fi
        echo
    fi

    # Get Clover source
    cd "${EDK2DIR}"
    getSOURCEFILE Clover "$CloverDIR" "$CLOVERSVNURL" "$CLOVERLOCALREPO"
    buildClover=$?

    # Is Clover need to be update
    if [[ "$buildClover" -eq 1 ]]; then
        # Get configuration files from Clover
        cp "${CloverDIR}/Patches_for_EDK2/tools_def.txt"  "${EDK2DIR}/Conf/"
        cp "${CloverDIR}/Patches_for_EDK2/build_rule.txt" "${EDK2DIR}/Conf/"

        # Patch edk2/Conf/tools_def.txt for GCC
        sed -ie 's!^\(DEFINE GCC47_[IA32X64]*_PREFIX *= *\).*!\1'${TOOLCHAIN}'/bin/x86_64-linux-gnu-!' \
         "${EDK2DIR}/Conf/tools_def.txt"
        checkit "    Patching edk2/Conf/tools_def.txt"

        echob "    Clover updated, so rm the build folder"
        rm -Rf "${buildDIR}"/*

        echob "    Copy Files/HFSPlus Clover/HFSPlus"
        cp -R "${filesDIR}/HFSPlus/" "${CloverDIR}/HFSPlus/"
    fi

    echo
}

# compiles X64 or IA32 versions of Clover and rEFIt_UEFI
function cleanRUN(){
    local builder=gcc
    local archs=$(echo "$1" | awk '{print toupper($0)}')
    echo
    echo "Starting $buildMode Process: $(date -j +%T)"
    echo "Building Clover$archs, gcc${mygccVers} $style"

    # Mount the RamDisk
    mountRamDisk "$EDK2DIR/Build"

    if [ "$archs" == "X64/IA32" ]; then
        cd "${CloverDIR}"
        for arch in x64 ia32; do
            echob "running ./ebuild.sh -gcc${mygccVers} -$arch -$style"
            ./ebuild.sh -gcc${mygccVers} -$arch -"$style"
            checkit "Clover$arch $style"
        done
        cd "${rEFItDIR}"
        echob "Building rEFIt32: $builder $style $(date -j +%T)"
        echob "With build32.sh"
        ./"build32.sh"
        checkit "rEFIT_UEFI_$archs: $style"
    else
        cd "${CloverDIR}"
        echob "running ./ebuild.sh -gcc${mygccVers} -x64 -$style"
        ./ebuild.sh -gcc${mygccVers} -x64 -"$style"
        checkit "CloverX64 $style"
    fi
    echo
}

function installToolchain() {
    cd "${WORKDIR}"/Files
    echo  "Download and install toolchain to compile Clover"
    printf "toolchain will be install in %s\n" $(echob ${TOOLCHAIN})
    echo  "Press any key to start the process..."
    read
    echob "Starting CloverGrower Compile Tools process..."
    date
    PREFIX="$TOOLCHAIN" DIR_MAIN="$srcDIR" DIR_TOOLS="$srcDIR/CloverTools" ./buildgcc.sh -x64 -all # build only x64 because it can compile ia32 too
    tput bel
    cd ..
}


autoBuild(){
    local theARCHS="$1"
    if [ "$built" == "No" ]; then
        local buildMess="*    Auto-Build Full Clover rEFIt_UEFI    *"
        local cleanMode=""
        buildMode=">>>>New<<<< Build "
        local edk2LocalRev=$(getSvnRevision "$EDK2DIR")
        echob "*******************************************"
        echob "$buildMess"
        echob "$(printf '*    Revisions:  edk2: %-19s*\n' $edk2LocalRev)"
        echob "$(printf '*              Clover: %-19s*\n' $versionToBuild)"
        local IFS=
        local flags="$mygccVers $theARCHS $style"
        echob "$(printf '*    Using Flags: gcc%-21s*\n' $flags)"
        echob "*******************************************"
        tput bel
        sleep 3
        local startEpoch=$(date -u "+%s")
        cleanRUN "$theARCHS"
        built="Yes"
        local stopEpoch=$(date -u "+%s")

        local buildTime=$(expr $stopEpoch - $startEpoch)
        local timeToBuild
        if [[ $buildTime -gt 59 ]]; then
            timeToBuild=$(printf "%dm%ds\n" $((buildTime/60%60)) $((buildTime%60)))
        else
            timeToBuild=$(printf "%ds\n" $((buildTime)))
        fi
        echob "Clover Grower Complete Build process took $timeToBuild to complete..."
    fi
}

# makes pkg if Built OR builds THEN makes pkg
function makePKG(){
    versionToBuild=""
    cloverUpdate="No"
    clear;echo
    echob "********************************************"
    echob "*             Good $hours               *"
    echob "*      Welcome To CloverGrower V$myV       *"
    echob "*       This script by STLVNUB/JrCs        *"
    echob "* Clover Credits: Slice, dmazar and others *"
    echob "********************************************"
    echo
    echob "running '$(basename $CMD)' on '$rootSystem'"
    echo
    echob "Work Folder: $WORKDIR"
    echob "Available  : ${workSpaceAvail} MB"
    local cloverRemoteRev=$(getSvnRevision "$CLOVERSVNURL")
    versionToBuild=$cloverRemoteRev
    if [ -f "${builtPKGDIR}/${versionToBuild}/Clover_v2_rL${versionToBuild}".pkg ] && [ -d "${CloverDIR}" ] && [ "$target" != "X64" ]; then # don't build IF pkg already here
        if [ -f "${builtPKGDIR}/${versionToBuild}"/CloverCD/EFI/BOOT/BOOTX64.efi ]; then
            theBuiltVersion=$(strings "${builtPKGDIR}/${versionToBuild}/CloverCD/EFI/BOOT/BOOTX64.efi" | sed -n 's/^Clover revision: *//p')
            if [ "${theBuiltVersion}" == "${versionToBuild}" ]; then
                built="Yes"
            else
                built="No "
                cloverUpdate="Yes"
            fi
            local cloverLocalRev=$(getSvnRevision "${CloverDIR}")
            echob  "******** Clover Package STATS **********"
            echob "$(printf '*       local  revision at %-12s*\n' $cloverLocalRev)"
            echob "$(printf '*       remote revision at %-12s*\n' $cloverRemoteRev)"
            echob "$(printf '*       Package Built   =  %-12s*\n' $built)"
            echob "****************************************"
            if [ "$built" == "Yes" ]; then
                echob "Clover_v2_rL${versionToBuild}.pkg ALREADY Made!!"
                return
            fi
        fi
    fi

    echo
    if [[ ! -d "${CloverDIR}" ]]; then
        cloverUpdate="Yes"
    else
        local cloverLocalRev=$(getSvnRevision "${CloverDIR}")
        if [[ "${cloverLocalRev}" != "${versionToBuild}" ]]; then
            echob "Clover Update Detected !"
            cloverUpdate="Yes"
            echob  "******** Clover Package STATS **********"
            echob "$(printf '*       local  revision at %-12s*\n' $cloverLocalRev)"
            echob "$(printf '*       remote revision at %-12s*\n' $cloverRemoteRev)"
            echob "$(printf '*       Package Built   =  %-12s*\n' $built)"
            echob "****************************************"
        else
            echob "No Clover Update found. Current revision: ${cloverLocalRev}"
        fi
    fi

    echo
    if [[ "${cloverUpdate}" == "Yes" ]]; then
        echob "Getting SVN Source, Hang ten…"
        getSOURCE
    fi

    # If not already built force Clover build
    if [[ "$built" == "No" ]]; then
        echob "No build already done. Forcing Clover build"
        echo
        buildClover=1
    fi

    if [[ "$buildClover" -eq 1 ]]; then
        echob "Ready to build Clover $versionToBuild, Using Gcc $gccVersToUse"
        autoBuild "$1"
    fi

	if [ "$target" == "X64/IA32" ]; then
		if [ ! -f "${builtPKGDIR}/${versionToBuild}/Clover_v2_rL${versionToBuild}".pkg ]; then # make pkg if not there
			echob "Type 'm' To make Clover_v2_rL${versionToBuild}.pkg..."
			read choose
			case $choose in
			m|M)
			if [ -d "${CloverDIR}"/CloverPackage/sym ]; then
				rm -rf "${CloverDIR}"/CloverPackage/sym
			fi
			if [ -f "${UserDIR}"/rc.local ] || [ -f "${UserDIR}"/rc.shutdown.local ]; then
				if [ -f "${UserDIR}"/rc.local ]; then
					echob "copy User rc.local To Package"
					cp -R "${UserDIR}"/rc.local "${CloverDIR}"/CloverPackage/CloverV2/etc
				fi
					
				if [ -f "${UserDIR}"/rc.shutdown.local ]; then
					echob "copy User rc.shutdown.local To Package"
					cp -R "${UserDIR}"/rc.shutdown.local "${CloverDIR}"/CloverPackage/CloverV2/etc
				fi	
			fi	
			cd "${CloverDIR}"/CloverPackage
			echob "cd to ${CloverDIR}/CloverPackage and run ./makepkg."
			./makepkg "No"
			wait
			echob "mkdir buildPKG/${versionToBuild}."
			mkdir "${builtPKGDIR}"/"${versionToBuild}"
			echob "cp ${CloverDIR}/CloverPackage/sym/ builtPKG/${versionToBuild}."
			cp -R "${CloverDIR}"/CloverPackage/sym/ "${builtPKGDIR}"/"${versionToBuild}"/
			echob "rm -rf ${CloverDIR}/CloverPackage/sym."
			rm -rf "${CloverDIR}"/CloverPackage/sym
			echob "open builtPKG/${versionToBuild}."
			open "${builtPKGDIR}"/"${versionToBuild}"
			tput bel
			;;
			*)
			esac
		else
			echob "Clover_v2_rL${versionToBuild}.pkg ALREADY Made !"
		fi
	else
        echob "Skipping pkg creation, 64bit Build Only"
        open "${cloverPKGDIR}"/CloverV2/
	fi
}

# Check CloverGrower build environment
checkEnv

export mygccVers="${gccVersToUse:0:1}${gccVersToUse:2:1}" # needed for BUILD_TOOLS e.g GCC47
buildMess="*    Auto-Build Full Clover rEFIt_UEFI    *"
cleanMode=""
built="No"

makePKG "$target" # do complete build

echob "Good $hours."
