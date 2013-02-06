#!/bin/bash

declare -r CloverGrowerVersion="5.0"
declare -r gccVersToUse="4.7.2" # failsafe check
declare -r self="${0##*/}"

# Reset locales (important when grepping strings from output commands)
export LC_ALL=C

# Retrieve full path of the command
declare -r CMD=$([[ $0 == /* ]] && echo "$0" || echo "${PWD}/${0#./}")

# Retrieve full path of CloverGrowerPro
declare -r CLOVER_GROWER_PRO_SCRIPT=$(readlink "$CMD" || echo "$CMD")
declare -r CLOVER_GROWER_PRO_DIR=${CLOVER_GROWER_PRO_SCRIPT%/*}
declare -r CLOVER_GROWER_PRO_CONF="$CLOVER_GROWER_PRO_DIR/CloverGrowerPro.conf"

# Command line arguments
declare -r ARGS="$@"

# Source librarie
source "$CLOVER_GROWER_PRO_DIR/CloverGrowerPro.lib"

# Source config file
[[ ! -f "$CLOVER_GROWER_PRO_CONF" ]] && touch "$CLOVER_GROWER_PRO_CONF"
source "$CLOVER_GROWER_PRO_CONF"

target="X64"

MAKE_PACKAGE=1
CLOVER_REMOTE_REV=
CLOVER_LOCAL_REV=
FORCE_REVISION=

# Usage: usage
# Print the usage.
usage () {
    printf "Usage: %s [OPTION]\n" "$self"
    echo "Compile Clover UEFI/Bios OS X Booter"
    echo
    printOptionHelp "-r, --revision" "compile a specific Clover revision"
    printOptionHelp "-t, --target" "choose target(s) to build [default=x64]. You can specify multiple targets (ie. --target=\"ia32 x64\")"
    printOptionHelp "-h, --help" "print this message and exit"
    printOptionHelp "-v, --version" "print the version information and exit"
    echo
    echo "Report any issue to https://github.com/JrCs/CloverGrowerPro/issues"; echo
}

function checkOptions() {
    if [[ -n "$FORCE_REVISION" && ! "$FORCE_REVISION" =~ ^[0-9]*$ ]];then
        echo "Invalid revision '$FORCE_REVISION': must be an integer !" >&2
        exit 1
    fi
}

function checkConfig() {
    if [[ -z "$CHECKUPDATEINTERVAL" ]];then
        local updateInterval
        local msg=$(printf "Check for CloverGrowerPro update every %say/%seek/%sonth/%sever" \
                    $(echob "D") $(echob "W") $(echob "M") $(echob "N"))
        while [[ -z "$CHECKUPDATEINTERVAL" ]]; do
            CHECKUPDATEINTERVAL=$(prompt "$msg" "W")
            case "$CHECKUPDATEINTERVAL" in
                [Nn]) CHECKUPDATEINTERVAL=-1       ;;
                [Dd]) CHECKUPDATEINTERVAL=86400    ;;
                [Ww]) CHECKUPDATEINTERVAL=604800   ;;
                [Mm]) CHECKUPDATEINTERVAL=18446400 ;;
                *)    CHECKUPDATEINTERVAL= ;;
            esac
        done
        storeConfig 'CHECKUPDATEINTERVAL' "$CHECKUPDATEINTERVAL"
    fi
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
}

function checkUpdate() {
    local check_timestamp_file="$CLOVER_GROWER_PRO_DIR/.last_check"
    local last_check=$(cat "$check_timestamp_file" 2>/dev/null)
    local now=$(date '+%s')
    if [[ $(( ${last_check:-0} + $CHECKUPDATEINTERVAL )) -lt $now ]]; then
        echo "Checking for new version of CloverGrowerPro..."
        (cd "$CLOVER_GROWER_PRO_DIR" && LC_ALL=C git pull -f) || exit 1
        echo "$now" > "$check_timestamp_file"
        exec "$0" $ARGS
    fi
}

function argument() {
    local opt=$1
    shift
    if [[ $# -eq 0 ]]; then
        printf "%s: option \`%s' requires an argument\n" "$0" "$opt" 1>&2
        exit 1
    fi
    echo $1
}

# Check the arguments.
while [[ $# -gt 0 ]]; do
    option=$1

    case "$option" in
        -h | --help)
                     usage
                     exit 0 ;;
        -v | --version)
                     echo "$self $CloverGrowerVersion"
                     exit 0 ;;
        -r | --revision)
                     shift
                     FORCE_REVISION=$(argument $option "$@"); shift;;
        --revision=*)
                     shift
                     FORCE_REVISION=$(echo "$option" | sed 's/--revision=//')
                     ;;
        -t | --target)
                     shift
                     target=$(argument $option "$@"); shift;;
        --target=*)
                     shift
                     target=$(echo "$option" | sed 's/--target=//')
                     ;;
        *)
            printf "Unrecognized option \`%s'\n" "$option" 1>&2
            usage
            exit 1
            ;;
    esac
done

checkOptions
checkConfig
checkUpdate

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
    if [[ ! -L "/usr/local/bin/cloverpro" || $(readlink "/usr/local/bin/cloverpro") != "$CLOVER_GROWER_PRO_SCRIPT" ]]; then
        echob "Running CloverGrowerPro.sh"
        printf "Will create link %s to %s\n" $(echob "/usr/local/bin/clover") $(echob "CloverGrowerPro.sh")
        echob "You can THEN 'run' CloverGrowerPro.sh by typing 'cloverpro' ;)"
        echob "Press Enter to continue"
        read
        if [ ! -d /usr/local/bin ]; then
            command="sudo mkdir -p /usr/local/bin"; echob "$command" ; eval $command
        fi
        command="sudo ln -sf $CLOVER_GROWER_PRO_SCRIPT /usr/local/bin/cloverpro && sudo chown $theBoss /usr/local/bin/cloverpro"
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
    for d in "$cloverPKGDIR"/CloverV2/EFI/drivers64UEFI ; do
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
}

# checkout/update svn
# $1=name $2=Local folder, $3=svn Remote url
# return code:
#     0: no update found
#     1: update found
function getSOURCEFILE() {
    local name="$1"
    local localdir="$2"
    local svnremoteurl="$3"
    local remoteRev=$(getSvnRevision "$svnremoteurl")
    if [[ ! -d "$localdir" ]]; then
        echob "    ERROR:"
        echo  "        Local $localdir folder not found.."
        echob "        Making local ${localdir} folder..."
        mkdir "$localdir"
    fi
    if [[ ! -d "${localdir}/.svn" && ! -d "${localdir}/.git" ]]; then
        echob "    Checking out Remote $name revision $remoteRev"
        checkout_repository "$localdir" "$svnremoteurl"
        return 1
    fi

    local localRev=$(getSvnRevision "$localdir")
    local checkoutRev=$remoteRev
    [[ "$localdir" == */Clover ]] && checkoutRev=${FORCE_REVISION:-$remoteRev}

    if [[ "${localRev}" == "${checkoutRev}" ]]; then
        echob "    Checked $name SVN, 'No updates were found...'"
        return 0
    fi
    echob "    Checked $name SVN, 'Updates found...'"
    echob "    Auto Updating $name From $localRev to $checkoutRev ..."
    tput bel
    if [[ "$localdir" == */Clover ]]; then
        update_repository "$localdir" "$checkoutRev"
    else
        update_repository "$localdir"
    fi
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
    getSOURCEFILE Clover "$CloverDIR" "$CLOVERSVNURL"
    buildClover=$?

    echo
}

# compiles X64 or IA32 versions of Clover and rEFIt_UEFI
function cleanRUN(){
    local builder=gcc
    local archs=$(echo "$1" | awk '{print toupper($0)}')
    echo
    echo "Starting $buildMode Process: $(date -j +%T)"
    echo "Building Clover$archs, gcc${mygccVers} $style"

    # Check that all the needed directories are created
    checkDirs

    # Mount the RamDisk
    mountRamDisk "$EDK2DIR/Build"

    cd "${CloverDIR}"
    local IFS=" /" # archs can be separate by space or /
    local archs=$(lc $archs)
    unset IFS
    for arch in $archs; do
        echob "running ./ebuild.sh -gcc${mygccVers} -$arch -$style"
        ./ebuild.sh -gcc${mygccVers} -$arch -"$style"
        checkit "Clover$arch $style"
    done
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
        echo
    fi
}

# makes pkg if Built OR builds THEN makes pkg
function makePKG(){
    echo
    echob "********************************************"
    echob "*              Good $hours              *"
    echob "*     Welcome To CloverGrowerPro v$CloverGrowerVersion      *"
    echob "*           This script by JrCs            *"
    echob "*        Original script by STLVNUB        *"
    echob "* Clover Credits: Slice, dmazar and others *"
    echob "********************************************"
    echo
    echob "running '$(basename $CMD)' on '$rootSystem'"
    echo
    echob "Work Folder: $WORKDIR"
    echob "Available  : ${workSpaceAvail} MB"
    echo

    cloverUpdate="No"
    versionToBuild=

    if [[ -d "${CloverDIR}" ]]; then
        CLOVER_LOCAL_REV=$(getSvnRevision "${CloverDIR}")
        if [[ -d "${CloverDIR}/.git" ]]; then
            # Check if we are on the master branch
            local branch=$(cd "$CloverDIR" && LC_ALL=C git rev-parse --abbrev-ref HEAD)
            if [[ "$branch" != master ]]; then
                echob "You're not on the 'master' branch. Can't update the repository !"
                versionToBuild=$CLOVER_LOCAL_REV
            fi
        fi
        if [[ -z "$versionToBuild" ]]; then
            if [[ -n "$FORCE_REVISION" ]]; then
                versionToBuild=$FORCE_REVISION
            else
                CLOVER_REMOTE_REV=$(getSvnRevision "$CLOVERSVNURL")
                versionToBuild=$CLOVER_REMOTE_REV
            fi

            if [[ -n "$FORCE_REVISION" ]]; then
                versionToBuild=$FORCE_REVISION
                if [[ "${CLOVER_LOCAL_REV}" -ne "${versionToBuild}" ]]; then
                    echob "Forcing Clover revision $versionToBuild"
                    cloverUpdate="Yes"
                fi
            else
                if [[ "${CLOVER_LOCAL_REV}" -ne "${versionToBuild}" ]]; then
                    echob "Clover Update Detected !"
                    echob  "******** Clover Package STATS **********"
                    echob "$(printf '*       local  revision at %-12s*\n' $CLOVER_LOCAL_REV)"
                    echob "$(printf '*       remote revision at %-12s*\n' $CLOVER_REMOTE_REV)"
                    echob "$(printf '*       Package Built   =  %-12s*\n' $built)"
                    echob "****************************************"
                    cloverUpdate="Yes"
                else
                    echob "No Clover Update found. Current revision: ${CLOVER_LOCAL_REV}"
                fi
            fi
        fi
    else
        CLOVER_LOCAL_REV=0
        cloverUpdate="Yes"
    fi

    # if [ -f "${builtPKGDIR}/${versionToBuild}/Clover_v2_rL${versionToBuild}".pkg ] && [ -d "${CloverDIR}" ] && [ "$target" != "X64" ]; then # don't build IF pkg already here
    #     if [ -f "${builtPKGDIR}/${versionToBuild}"/CloverCD/EFI/BOOT/BOOTX64.efi ]; then
    #         theBuiltVersion=$(strings "${builtPKGDIR}/${versionToBuild}/CloverCD/EFI/BOOT/BOOTX64.efi" | sed -n 's/^Clover revision: *//p')
    #         if [ "${theBuiltVersion}" == "${versionToBuild}" ]; then
    #             built="Yes"
    #         else
    #             built="No "
    #             cloverUpdate="Yes"
    #         fi
    #         echob  "******** Clover Package STATS **********"
    #         echob "$(printf '*       local  revision at %-12s*\n' $CLOVER_LOCAL_REV)"
    #         echob "$(printf '*       remote revision at %-12s*\n' $CLOVER_REMOTE_REV)"
    #         echob "$(printf '*       Package Built   =  %-12s*\n' $built)"
    #         echob "****************************************"
    #         if [ "$built" == "Yes" ]; then
    #             echob "Clover_v2_rL${versionToBuild}.pkg ALREADY Made!!"
    #             return
    #         fi
    #     fi
    # fi

    echo
    if [[ "${cloverUpdate}" == "Yes" ]]; then
        echob "Getting SVN Source, Hang ten…"
        getSOURCE
        CLOVER_LOCAL_REV=$(getSvnRevision "${CloverDIR}") # Update
    fi

    if [[ "$cloverUpdate" == "Yes" || ! -f "${EDK2DIR}/Conf/tools_def.txt" ]]; then
        # get configuration files from Clover
        cp "${CloverDIR}/Patches_for_EDK2/tools_def.txt"  "${EDK2DIR}/Conf/"
        cp "${CloverDIR}/Patches_for_EDK2/build_rule.txt" "${EDK2DIR}/Conf/"

        # Patch edk2/Conf/tools_def.txt for GCC
        sed -i'.orig' -e 's!^\(DEFINE GCC47_[IA32X64]*_PREFIX *= *\).*!\1'${TOOLCHAIN}'/bin/x86_64-linux-gnu-!' \
         "${EDK2DIR}/Conf/tools_def.txt"
        checkit "Patching edk2/Conf/tools_def.txt"

        echob "Clover updated, so rm the build folder"
        rm -Rf "${buildDIR}"/*

        echob "Copy Files/HFSPlus Clover/HFSPlus"
        cp -R "${filesDIR}/HFSPlus/" "${CloverDIR}/HFSPlus/"
    fi

    # If not already built force Clover build
    if [[ "$built" == "No" ]]; then
        echob "No build already done. Forcing Clover build"
        echo
        buildClover=1
    fi

    if [[ "$buildClover" -eq 1 ]]; then
        echob "Ready to build Clover $CLOVER_LOCAL_REV, Using Gcc $gccVersToUse"
        autoBuild "$1"
    fi

	if [ "$MAKE_PACKAGE" -eq 1 ]; then
		local package_name="Clover_v2_r${versionToBuild}.pkg"
		if [[ ! -f "${builtPKGDIR}/${versionToBuild}/$package_name" ]]; then # make pkg if not there
			echob "Type 'm' To make ${package_name}..."
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
			echob "$package_name ALREADY Made !"
		fi
	else
        echob "Skipping pkg creation,"
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
