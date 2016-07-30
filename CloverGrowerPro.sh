#!/bin/bash

declare -r CloverGrowerVersion="5.0"
declare -r self="${0##*/}"

# Reset locales (important when grepping strings from output commands)
export LC_ALL=C

# Retrieve full path of the command
declare -r CMD=$(readlink "$0" || echo "$0")
# Retrieve full path of CloverGrowerPro
declare -r CLOVER_GROWER_PRO_DIR="$(cd "$(dirname "$CMD")" && echo "$PWD")"
declare -r CLOVER_GROWER_PRO_SCRIPT="$CLOVER_GROWER_PRO_DIR/$(basename "$CMD")"
declare -r CLOVER_GROWER_PRO_CONF="$CLOVER_GROWER_PRO_DIR/CloverGrowerPro.conf"

# Source librarie
source "$CLOVER_GROWER_PRO_DIR/CloverGrowerPro.lib"

# Check that CloverGrowerPro is well installed
if [[ ! -e "$CLOVER_GROWER_PRO_DIR"/.git ]]; then
    error "Bad installation !"
    sayColor red "$self must be installed with the git clone command and not from an archive !"
    sayColor red "See https://github.com/JrCs/CloverGrowerPro/blob/master/README.md for more information"
    exit 1
fi

# Source config file
[[ ! -f "$CLOVER_GROWER_PRO_CONF" ]] && touch "$CLOVER_GROWER_PRO_CONF"
source "$CLOVER_GROWER_PRO_CONF"

DO_SETUP=
MAKE_PACKAGE=1
CLOVER_REMOTE_REV=
CLOVER_LOCAL_REV=
FORCE_REVISION=
FORCE_CHECK_UPDATE=0
UPDATE_SOURCES=1
FW_VBIOS_PATH=
USE_LOCAL_BUILDGCC=0

# Usage: usage
# Print the usage.
usage () {
    printf "Usage: %s [OPTION]\n" "$self"
    echo "Compile Clover UEFI/Bios OS X Booter"
    echo
    printOptionHelp "-r, --revision"     "compile a specific Clover revision"
    printOptionHelp "-t, --target"       "choose target(s) to build [default=x64]. Targets currently supported: ia32, x64 and x64-mcp. You can specify multiple targets (ie. --target=\"ia32 x64\")."
    printOptionHelp "-u, --check-update" "force check update."
    printOptionHelp "-n, --no-source-updates" "Disable clover and edk2 source updates."
    printOptionHelp "-s, --setup"        "setup $self."
    printOptionHelp "-h, --help"         "print this message and exit"
    printOptionHelp "-v, --version"      "print the version information and exit"
    echo
    echo "Report any issue to https://github.com/JrCs/CloverGrowerPro/issues"; echo
}

function checkOptions() {
    if [[ -n "$FORCE_REVISION" && ! "$FORCE_REVISION" =~ ^[0-9]*$ ]];then
        die "Invalid revision '$FORCE_REVISION': must be an integer !"
    fi
}

function checkConfig() {
    if [[ -z "$CHECKUPDATEINTERVAL" || -n "$DO_SETUP" ]];then
        local updateInterval
        local msg=$(printf "Check for CloverGrowerPro update every %say/%seek/%sonth/%sever" \
                    $(echob "D") $(echob "W") $(echob "M") $(echob "N"))

        local default_checkupdateinterval='W'

        case ${CHECKUPDATEINTERVAL} in
            -1)       default_checkupdateinterval='N' ;;
            86400)    default_checkupdateinterval='D' ;;
            18446400) default_checkupdateinterval='M' ;;
        esac

        CHECKUPDATEINTERVAL=
        while [[ -z "$CHECKUPDATEINTERVAL" ]]; do
            CHECKUPDATEINTERVAL=$(prompt "$msg" "$default_checkupdateinterval")
            case "$CHECKUPDATEINTERVAL" in
                [Nn]) CHECKUPDATEINTERVAL=-1       ;;
                [Dd]) CHECKUPDATEINTERVAL=86400    ;;
                [Ww]) CHECKUPDATEINTERVAL=604800   ;;
                [Mm]) CHECKUPDATEINTERVAL=18446400 ;;
                *)    CHECKUPDATEINTERVAL= ;;
            esac
        done
        storeConfig 'CHECKUPDATEINTERVAL' "$CHECKUPDATEINTERVAL"
        echo
    fi

    if [[ -z "$TOOLCHAIN" || -n "$DO_SETUP" ]];then
        echo "Where to put the toolchain directory ?"
        local default_toolchain="${TOOLCHAIN:-${CLOVER_GROWER_PRO_DIR}/toolchain}"
        TOOLCHAIN=$(prompt "TOOCHAIN directory" "$default_toolchain")
        storeConfig 'TOOLCHAIN' "$TOOLCHAIN"
        echo
    fi

    if [[ -z "$EDK2DIR" || -n "$DO_SETUP" ]];then
        echo "Where to put the edk2 source files ?"
        local default_edk2dir="${EDK2DIR:-${CLOVER_GROWER_PRO_DIR}/edk2}"
        EDK2DIR=$(prompt "edk2 directory" "$default_edk2dir")
        storeConfig 'EDK2DIR' "$EDK2DIR"
        echo
    fi

    if [[ -z "$CLOVERSVNURL" || -n "$DO_SETUP" ]]; then
        local default_developer='No'
        local default_login=''
        case "$CLOVERSVNURL" in
            *svn+ssh:*) default_developer='Yes'
                        default_login=$(echo "$CLOVERSVNURL" | sed -nE 's#.*//(.+)@.*#\1#p')
                        ;;
        esac
        local developer=$(prompt "Do you have the rights to commit Clover source files" "$default_developer")
        local login
        if [[ $(lc "$developer") == y* ]];then
            login=$(prompt "What is your login on sourceforge.net" "$default_login")
        fi
        if [[ -n "$login" ]];then
            CLOVERSVNURL="svn+ssh://$login@svn.code.sf.net/p/cloverefiboot/code"
        else
            CLOVERSVNURL='svn://svn.code.sf.net/p/cloverefiboot/code'
        fi
        storeConfig 'CLOVERSVNURL' "$CLOVERSVNURL"
        echo
    fi

    if [[ -z "$EDK2SVNURL" || -n "$DO_SETUP" ]]; then
        local default_edk2_svn_url='svn://svn.code.sf.net/p/edk2/code/trunk/edk2'
        EDK2SVNURL=$(prompt "EDK2 svn url to use" "${EDK2SVNURL:-$default_edk2_svn_url}")
        storeConfig 'EDK2SVNURL' "$EDK2SVNURL"
        echo
    fi

    if [[ -z "$DEFAULT_TARGET" || -n "$DO_SETUP" ]];then
        DEFAULT_TARGET=$(prompt "Default target(s) to use (ia32, x64, x64-mcp)" "${DEFAULT_TARGET:-x64}")
        storeConfig 'DEFAULT_TARGET' "$DEFAULT_TARGET"
        echo
    fi
    case "$DEFAULT_TARGET" in
      mc) DEFAULT_TARGET=x64-mcp; storeConfig 'DEFAULT_TARGET' "$DEFAULT_TARGET";;
    esac

    if [[ -z "$VBIOS_PATCH_IN_CLOVEREFI" || -n "$DO_SETUP" ]];then
        local default_vbios_patch_in_cloverefi='No'
        [[ "$VBIOS_PATCH_IN_CLOVEREFI" -ne 0 ]] && \
         default_vbios_patch_in_cloverefi='Yes'
        local answer=$(prompt "Activate VBios Patch in CloverEFI by default" \
         "$default_vbios_patch_in_cloverefi")
        VBIOS_PATCH_IN_CLOVEREFI=0
        [[ $(lc "$answer") == y* ]] && VBIOS_PATCH_IN_CLOVEREFI=1
        storeConfig 'VBIOS_PATCH_IN_CLOVEREFI' "$VBIOS_PATCH_IN_CLOVEREFI"
        echo
    fi

    if [[ -z "$ONLY_SATA0_PATCH" || -n "$DO_SETUP" ]];then
        local default_only_sata0_patch='No'
        [[ "$ONLY_SATA0_PATCH" -ne 0 ]] && \
         default_only_sata0_patch='Yes'
        local answer=$(prompt "Activate Only SATA0 Patch by default" \
         "$default_only_sata0_patch")
        ONLY_SATA0_PATCH=0
        [[ $(lc "$answer") == y* ]] && ONLY_SATA0_PATCH=1
        storeConfig 'ONLY_SATA0_PATCH' "$ONLY_SATA0_PATCH"
        echo
    fi

    if [[ -z "$ENABLE_SECURE_BOOT" || -n "$DO_SETUP" ]];then
        local default_enable_secure_boot='No'
        [[ "$ENABLE_SECURE_BOOT" -ne 0 ]] && \
         default_enable_secure_boot='Yes'
        local answer=$(prompt "Enable Secure Boot" \
         "$default_enable_secure_boot")
        ENABLE_SECURE_BOOT=0
        [[ $(lc "$answer") == y* ]] && ENABLE_SECURE_BOOT=1
        storeConfig 'ENABLE_SECURE_BOOT' "$ENABLE_SECURE_BOOT"
        echo
    fi

    if [[ -z "$USE_APPLE_HFSPLUS_DRIVER" || -n "$DO_SETUP" ]];then
        local default_use_apple_hfs_driver='Yes'
        [[ "${USE_APPLE_HFSPLUS_DRIVER:-1}" -ne 1 ]] && \
         default_use_apple_hfs_driver='No'
        local msg=$(printf "Use Apple HFS+ driver (%so, %ses)" \
                    $(echob "N") $(echob "Y"))
        local answer=$(prompt "$msg" "$default_use_apple_hfs_driver" 'N' 'Y')
        USE_APPLE_HFSPLUS_DRIVER=1
        [[ $(lc "$answer") == n* ]] && USE_APPLE_HFSPLUS_DRIVER=0
        storeConfig 'USE_APPLE_HFSPLUS_DRIVER' "$USE_APPLE_HFSPLUS_DRIVER"
        echo
    fi

    if [[ -n "$DO_SETUP" ]];then
        local default_ebuild_optional_args=''
        EBUILD_OPTIONAL_ARGS=$(echo "$EBUILD_OPTIONAL_ARGS" | sed -E 's/-D *(ENABLE_SECURE_BOOT|USE_APPLE_HFSPLUS_DRIVER)//g;s/^ *//;s/ *$//;s/  +/ /g')
        EBUILD_OPTIONAL_ARGS=$(prompt "Additionnal parameters to pass to ebuild.sh script" "${EBUILD_OPTIONAL_ARGS:-}")
        storeConfig 'EBUILD_OPTIONAL_ARGS' "$EBUILD_OPTIONAL_ARGS"
        echo
    fi

    if [[ -z "$BUILD_PACKAGE" || -n "$DO_SETUP" ]]; then
        local default_build_package="${BUILD_PACKAGE:-Ask}"
        local msg=$(printf "Build the installer package after the compilation (%so, %ssk, %ses)" \
                    $(echob "N") $(echob "A") $(echob "Y"))
		local answer=$(prompt "$msg" "$default_build_package" 'N' 'A' 'Y')
        case $(lc "$answer") in
            n*) BUILD_PACKAGE='No'  ;;
            y*) BUILD_PACKAGE='Yes' ;;
            *)  BUILD_PACKAGE='Ask' ;;
        esac
		storeConfig 'BUILD_PACKAGE' "$BUILD_PACKAGE"
        echo
    fi
}

function checkUpdate() {
    [[ "$CHECKUPDATEINTERVAL" -lt 0 && "$FORCE_CHECK_UPDATE" -eq 0 ]] && return
    local check_timestamp_file="$CLOVER_GROWER_PRO_DIR/.last_check"
    local last_check=0
    [[ "$FORCE_CHECK_UPDATE" -eq 0 ]] && last_check=$(cat "$check_timestamp_file" 2>/dev/null)
    local now=$(date '+%s')
    if [[ $(( ${last_check:-0} + ${CHECKUPDATEINTERVAL:-604800} )) -lt $now ]]; then
        echo "Checking for new version of CloverGrowerPro..."
        (cd "$CLOVER_GROWER_PRO_DIR" && LC_ALL=C git pull --rebase -f) || exit 1
        echo "$now" > "$check_timestamp_file"
        exec "$0" "${ARGS[@]}"
    fi
}

argument() {
    local opt=$1
    shift
    if [[ $# -eq 0 ]]; then
        die $(printf "%s: option \`%s' requires an argument\n" "$0" "$opt")
    fi
    echo $1
}

function checkCloverLink() {
    if [[ ! -L "/usr/local/bin/cloverpro" || $(readlink "/usr/local/bin/cloverpro") != "$CLOVER_GROWER_PRO_SCRIPT" ]]; then
        echob "Running CloverGrowerPro.sh"
        printf "Will create link %s to %s\n" $(echob "/usr/local/bin/cloverpro") $(echob "CloverGrowerPro.sh")
        echob "You can THEN 'run' CloverGrowerPro.sh by typing 'cloverpro' ;)"
        echob "Press Enter to continue"
        read
        if [ ! -d /usr/local/bin ]; then
            command="sudo mkdir -p /usr/local/bin"; echob "$command" ; eval $command
        fi
        command="sudo ln -sf '$CLOVER_GROWER_PRO_SCRIPT' /usr/local/bin/cloverpro && sudo chown $theBoss /usr/local/bin/cloverpro"
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
    if [[ ! -x "${TOOLCHAIN}/bin/msgmerge" ]]; then
        installGettext
    fi
    if [[ ! -x "${TOOLCHAIN}/bin/gcc" || ! -x "${TOOLCHAIN}/cross/bin/x86_64-clover-linux-gnu-gcc" ]]; then
        installToolchain
    fi
    if [[ ! -x "${TOOLCHAIN}/bin/nasm" ]]; then
        installNasm
    fi
}

# Check the build environment
function checkEnv() {
    checkCloverLink
    checkXCode

    # Check for svn
    [[ -z $(type -P svn) ]] && { echob "svn command not found. Exiting..." >&2 ; exit 1; }

    # Check that some directories exists
    if [ ! -d "${srcDIR}" ]; then
        echob "Make src Folder.."
        mkdir "${srcDIR}"
    fi

    # Check the toolchain
    checkToolchain
}

function getCloverLastModifiedSource() {
    find "$CloverDIR/"                                                                             \
     -type d \( -path '*/.svn' -o -path '*/.git' -o -path '*/CloverPackage/CloverV2'               \
     -o -path '*/CloverPackage/sym' -o -path '*/CloverPackage/CloverUpdater'                       \
     -o -path '*/CloverPackage/CloverPrefpane'                                        \) -prune -o \
     -type f -print0 | xargs -0 stat -f "%m %N" |                                                  \
     egrep -v 'vers.txt|Version.h|revision|version|.DS_Store|\.efi$' | sort -n | tail -1 |         \
     cut -f1 -d' ' # ' fix xemacs fontification
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
    local remoteRev # Don't define and affect a variable in a single line to retrieve return code
    remoteRev=$(getSvnRevision "$svnremoteurl")
    [[ $? -ne 0 ]] && return 1
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

    printf "    %s, %s\n" "$(echob Checked $name SVN)" "$(sayColor info Updates found...)"
    printf "    %s %s %s %s ...\n" "$(sayColor info Auto Updating $name From)" "$(sayColor yellow $localRev)" "$(sayColor info 'to')" "$(sayColor green $checkoutRev)"
    tput bel

    if [[ "$localdir" == */Clover ]]; then
        update_repository --remote-url="$svnremoteurl" --force-revision="$checkoutRev" "$localdir"
    else
        # EDK2 directory
        # First revert local modifications done by EDK2 patches
        svn revert -q -R "$localdir"

        update_repository --remote-url="$svnremoteurl" "$localdir"
    fi

    checkit "    Svn up $name" "$svnremoteurl"

    return $?
}

# sets up svn sources
function getSOURCE() {
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
        getSOURCEFILE edk2 "$EDK2DIR" "$EDK2SVNURL"
        local return_code=$?
        if [[ $return_code -ne 0 && "$EDK2SVNURL" == svn://* ]]; then
            echo $(sayColor yellow "Can't get edk2 source from svn transport protocol !")
            echo $(sayColor yellow "Trying http transport protocol...")
            EDK2SVNURL=$(echo "http${EDK2SVNURL#svn}")
            getSOURCEFILE edk2 "$EDK2DIR" "$EDK2SVNURL"
            return_code=$?
        fi
        [[ $return_code -ne 0 ]] && echo $(sayColor red "Unable to checkout new EDK2 sources !")

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
    local archs=$(echo "$1" | awk '{print toupper($0)}')

    # Clear the package dir before compilation
    [[ "$versionToBuild" -ge 1166 ]] && ./ebuild.sh cleanpkg &>/dev/null

    echo
    echo "Starting $buildMode Process: $(date -j +%T)"
    echo "Building Clover$archs, ${ebuildToolchainFlag} $style"

    # Mount the RamDisk
    mountRamDisk "$EDK2DIR/Build"

    cd "${CloverDIR}"
    local IFS=" /" # archs can be separate by space or /
    local archs=$(lc $archs)
    unset IFS
    echo "Using TOOLCHAIN_DIR='$TOOLCHAIN'"
    for arch in $archs; do
        echob "running ${EBUILD_COMMAND[@]} --$arch"
        echo
        TOOLCHAIN_DIR="$TOOLCHAIN" ${EBUILD_COMMAND[@]} --$arch
        checkit "Clover$arch $style"
    done

    echo
}

function installToolchain() {
    cd "${WORKDIR}"/Files
    echo  "Download and install toolchain to compile Clover"
    printf "toolchain will be install in %s\n" "$(echob "${TOOLCHAIN}")"
    echo  "Press any key to start the process..."
    read

    if [[ "$USE_LOCAL_BUILDGCC" -eq 1 ]]; then
        echob "Using local version of buildgcc.sh..."
        cp "$CloverDIR"/buildgcc-4.9.sh "$srcDIR"/buildgcc.sh
    else
        # Get the latest version of buildgcc.sh from clover
        echob "Checking out last version of buildgcc.sh from clover repository..."
        svn export --force "$CLOVERSVNURL"/buildgcc-4.9.sh "$srcDIR"/buildgcc.sh >/dev/null
    fi

    echob "Starting CloverGrower Compile Tools process..."
    date
    # build only x64 because it can compile ia32 too
    PREFIX="$TOOLCHAIN" DIR_MAIN="$CLOVER_GROWER_PRO_DIR" DIR_TOOLS="$srcDIR" \
     "$srcDIR"/buildgcc.sh -x64 -all
    checkit "Toolchain build"
    tput bel
    cd ..
}

function installGettext() {
    cd "${WORKDIR}"/Files

    # Get the latest version of buildgettext.sh from clover
    echob "Checking out last version of buildgettext.sh from clover..."
    svn export --force "$CLOVERSVNURL"/buildgettext.sh "$srcDIR"/buildgettext.sh >/dev/null

    echob "Starting CloverGrower Compile GetText process..."
    date
    # build gettext
    TOOLCHAIN_DIR="$TOOLCHAIN" DIR_MAIN="$srcDIR" DIR_TOOLS="$srcDIR/CloverTools" \
     "$srcDIR"/buildgettext.sh
    checkit "GetText binaries built"
    cd ..
}

function installNasm() {
    cd "${WORKDIR}"/Files

    # Get the latest version of buildnasl.sh from clover
    echob "Checking out last version of buildnasm.sh from clover..."
    svn export --force "$CLOVERSVNURL"/buildnasm.sh "$srcDIR"/buildnasm.sh >/dev/null

    echob "Starting CloverGrower Compile Nasm process..."
    date
    # build gettext
    TOOLCHAIN_DIR="$TOOLCHAIN" DIR_MAIN="$srcDIR" DIR_TOOLS="$srcDIR/CloverTools" \
     "$srcDIR"/buildnasm.sh
    checkit "NASM binary built"
    cd ..
}

autoBuild(){
    local theARCHS="$1"
    if [ "$built" == "No" ]; then
        local buildMess="*    Auto-Build Full Clover rEFIt_UEFI    *"
        local cleanMode=""
        buildMode=">>>>New<<<< Build "
        local edk2LocalRev=$(getSvnRevision "$EDK2DIR")
        local buildVersioncolor='green'
        [[ "$CLOVER_LOCAL_REV" -ne "$CLOVER_REMOTE_REV" ]] && buildVersioncolor='yellow'
        echob "*******************************************"
        echob "$buildMess"
        echob "$(printf '*    Revisions:   %s: %-29s%s\n' $(sayColor info 'edk2') $(sayColor green $edk2LocalRev) $(echob '*'))"
        echob "$(printf '*               %s: %-29s%s\n' $(sayColor info 'Clover') $(sayColor $buildVersioncolor $versionToBuild) $(echob '*'))"
        local IFS=
        local flags="$ebuildToolchainFlag $theARCHS $style"
        echob "$(printf '*    Using Flags: %-24s*\n' $flags)"
        echob "*******************************************"
        tput bel

        if [[ "$versionToBuild" -ge 3014 ]]; then
            # Copy files from Patches_for_EDK2
            rsync -a --exclude '.cache' "${CloverDIR}"/Patches_for_EDK2/ "${EDK2DIR}"/
        fi

        local startEpoch=$(date -u "+%s")
        # Start build process
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
        printf "%s %s %s\n" "$(sayColor info 'Clover Grower Complete Build process took')" \
         "$(sayColor green $timeToBuild)" "$(sayColor info 'to complete...')"
        echo
    fi
}

# makes pkg if Built OR builds THEN makes pkg
function makePKG(){
    local theARCHS="$1"
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
                if [[ "$UPDATE_SOURCES" -eq 1 ]]; then
                    CLOVER_REMOTE_REV=$(getSvnRevision "$CLOVERSVNURL")
                else
                    CLOVER_REMOTE_REV=$CLOVER_LOCAL_REV
                fi
                versionToBuild=$CLOVER_REMOTE_REV
            fi

            if [[ -n "$FORCE_REVISION" ]]; then
                versionToBuild=$FORCE_REVISION
                if [[ "${CLOVER_LOCAL_REV}" -ne "${versionToBuild}" ]]; then
                    printf "%s %s\n" "$(sayColor info 'Forcing Clover revision')" "$(sayColor yellow $versionToBuild)"
                    cloverUpdate="Yes"
                fi
            else
                if [[ "${CLOVER_LOCAL_REV}" -ne "${versionToBuild}" ]]; then
                    sayColor info "Clover Update Detected !"
                    echob  "******** Clover Package STATS **********"
                    echob "$(printf '*       local  revision at %-23s%s\n' $(sayColor yellow $CLOVER_LOCAL_REV)  $(echob '*'))"
                    echob "$(printf '*       remote revision at %-23s%s\n' $(sayColor green  $CLOVER_REMOTE_REV) $(echob '*'))"
                    echob "$(printf '*       Package Built   =  %-23s%s\n' $(sayColor info   $built) $(echob '*'))"
                    echob "****************************************"
                    cloverUpdate="Yes"
                else
                    printf "%s %s %s\n" "$(sayColor info 'No Clover Update found.')" \
                     "$(echob 'Current revision:')" "$(sayColor green ${CLOVER_LOCAL_REV})"
                fi
            fi
        fi
    else
        CLOVER_LOCAL_REV=0
        cloverUpdate="Yes"
    fi

    echo
    if [[ "${cloverUpdate}" == "Yes" ]]; then
        echob "Getting SVN Source, Hang ten…"
        getSOURCE
        CLOVER_LOCAL_REV=$(getSvnRevision "${CloverDIR}") # Update
        versionToBuild=$CLOVER_LOCAL_REV

        rm -Rf "${buildDIR}"/*
        checkit "Clover updated, so rm the build folder"

        cp -R "${filesDIR}/HFSPlus/" "${CloverDIR}/HFSPlus/"
        checkit "Copy Files/HFSPlus Clover/HFSPlus"

        # Only for clover revisions < 3014
        if [[ "$versionToBuild" -lt 3014 ]]; then
            if [[ -n "$FORCE_REVISION" || ! -f "${EDK2DIR}/Conf/tools_def.txt" || \
             $(grep -c 'GCC49_' "${EDK2DIR}/Conf/tools_def.txt") -eq 0         || \
             "${CloverDIR}/Patches_for_EDK2/tools_def.txt" -nt "${EDK2DIR}/Conf/tools_def.txt" ]]; then
                # First revert local modifications done by EDK2 patches
                svn revert -q -R "$EDK2DIR"

                # get configuration files from Clover
                cp "${CloverDIR}/Patches_for_EDK2/tools_def.txt"  "${EDK2DIR}/Conf/"
                cp "${CloverDIR}/Patches_for_EDK2/build_rule.txt" "${EDK2DIR}/Conf/"

                # tools_def.txt need to be patch for version < 2863
                if [[ "$versionToBuild" -lt 2863 ]]; then
                    # Patch edk2/Conf/tools_def.txt for GCC
                    sed -i'.orig' -e 's!^\(DEFINE GCC4[78]_[IA32X64]*_PREFIX *= *\).*!\1'${TOOLCHAIN}'/cross/bin/x86_64-clover-linux-gnu-!' \
                     "${EDK2DIR}/Conf/tools_def.txt"
                    # Patch edk2/Conf/tools_def.txt for NASM
                    sed -i'.orig' -e 's!^\(.*_NASM_PATH *= *\).*!\1'${TOOLCHAIN}'/bin/nasm!' \
                     "${EDK2DIR}/Conf/tools_def.txt"
                    checkit "Patching edk2/Conf/tools_def.txt for NASM"
                fi
            fi
        fi
    fi

    # Construct EBUILD_COMMAND
    EBUILD_COMMAND=("./ebuild.sh" "-${ebuildToolchainFlag}")

    # We can activate VBios Patch in CloverEFI since revision 1162 of Clover
    [[ "$VBIOS_PATCH_IN_CLOVEREFI" -ne 0 && "$versionToBuild" -ge 1162 ]] && \
     EBUILD_COMMAND+=("--vbios-patch-cloverefi")

    # We can activate Only SATA0 Patch in CloverEFI since revision 1853 of Clover
    [[ "$ONLY_SATA0_PATCH" -ne 0 && "$versionToBuild" -ge 1853 ]] && \
     EBUILD_COMMAND+=("--only-sata0")

    # We can activate Secure Bool in CloverEFI since revision 2436 of Clover
    [[ "$ENABLE_SECURE_BOOT" -ne 0 && "$versionToBuild" -ge 2436 ]] && \
     EBUILD_COMMAND+=(-D ENABLE_SECURE_BOOT)

    # Use Apple HFS+ driver
    [[ "$USE_APPLE_HFSPLUS_DRIVER" -eq 1 ]] && EBUILD_COMMAND+=(-D USE_APPLE_HFSPLUS_DRIVER)

    [[ -n "${EBUILD_OPTIONAL_ARGS:-}" ]] && EBUILD_COMMAND+=($EBUILD_OPTIONAL_ARGS)
    local check_ebuild_options="${EBUILD_COMMAND[@]} $theARCHS"
    local last_ebuild_options=""
    [[ -f "$last_ebuild_options_file" ]] && last_ebuild_options=$(cat "$last_ebuild_options_file")

    # Check last modified file
    local last_timestamp=$(getCloverLastModifiedSource)
    local last_save_timestamp=$(stat -f '%m' "$last_ebuild_options_file" 2>/dev/null || echo '0')

    # If not already built force Clover build
    if [[ "$built" == "No" && ( "$last_timestamp" -gt "$last_save_timestamp" || \
          "$last_ebuild_options" != "$check_ebuild_options" ) ]]; then
        printf "%s %s\n" "$(echob 'No build already done.')" \
         "$(sayColor info 'Forcing Clover build...')"
        echo
        buildClover=1
    fi

    if [[ "$buildClover" -eq 1 ]]; then
        echob "Ready to build Clover $versionToBuild, Using Gcc $gccVersToUse"
        autoBuild "$theARCHS"
        echo "$check_ebuild_options" > "$last_ebuild_options_file"
    fi
    if [ "$MAKE_PACKAGE" -eq 1 ]; then
        local package_name="Clover_v2_r${versionToBuild}.pkg"
        if [[ ! -f "${builtPKGDIR}/$package_name" ]]; then # make pkg if not there
            if [[ "$(lc $BUILD_PACKAGE)" == a* ]]; then
                echob "Type 'm' To make ${package_name}..."
                read choose
            else
                choose='m'
            fi

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
                     export GETTEXT_PREFIX="$TOOLCHAIN"
                     ./makepkg "No" || exit $?
                     [[ ! -d "${builtPKGDIR}" ]] && mkdir "${builtPKGDIR}"
                     cp -p "${CloverDIR}"/CloverPackage/sym/*.pkg "${builtPKGDIR}"/
                     rm -rf "${CloverDIR}"/CloverPackage/sym
                     echob "open builtPKG"
                     open "${builtPKGDIR}"/
                     tput bel
                     ;;
                *)
            esac
        else
            echob "$package_name ALREADY Made !"
        fi
    else
        echob "Skipping pkg creation."
        open "${cloverPKGDIR}"/CloverV2/
    fi
}

# Check the arguments.
declare -a ARGS=()
force_target=

set -e
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
                     FORCE_REVISION=$(argument $option "$@"); shift
                     ARGS[${#ARGS[*]}]="--revision=$FORCE_REVISION" ;;
        --revision=*)
                     shift
                     FORCE_REVISION=$(echo "$option" | sed 's/--revision=//')
                     ARGS[${#ARGS[*]}]="--revision=$FORCE_REVISION" ;;
        -t | --target)
                     shift
                     force_target=$(argument $option "$@"); shift
                     ARGS[${#ARGS[*]}]="--target=$target" ;;
        --target=*)
                     shift
                     force_target=$(echo "$option" | sed 's/--target=//')
                     ARGS[${#ARGS[*]}]="--target=$target" ;;
        -s | --setup)
                     shift
                     DO_SETUP=1
                     ARGS[${#ARGS[*]}]="$option" ;;
        -u | --check-update)
                     shift
                     FORCE_CHECK_UPDATE=1 ;;
        -n | --no-source-updates)
                     shift
                     UPDATE_SOURCES=0 ;;
        --use-local-buildgcc)
                     shift
                     USE_LOCAL_BUILDGCC=1 ;;
        *)
            printf "Unrecognized option \`%s'\n" "$option" 1>&2
            usage
            exit 1
            ;;
    esac

done
set +e

checkOptions
checkUpdate
checkConfig

target="${force_target:-$DEFAULT_TARGET}"
unset force_target

[[ $(lc "$BUILD_PACKAGE") == n* ]] && MAKE_PACKAGE=0

# don't use -e
set -u

theBoss=$(id -ur)
hours=$(get_hours)

#vars
export WORKDIR="$CLOVER_GROWER_PRO_DIR"
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
last_ebuild_options_file="$filesDIR"/.last_ebuild_options
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
    [0-8]) rootSystem="unsupported" ;;
     9) rootSystem="Leopard" ;;
    10) rootSystem="Snow Leopard" ;;
    11) rootSystem="Lion" ;;
    12) rootSystem="Mountain Lion" ;;
    13) rootSystem="Mavericks" ;;
    14) rootSystem="Yosemite" ;;
    15) rootSystem="El Capitan" ;;
     *) rootSystem="Unknown" ;;
esac

# Check CloverGrower build environment
checkEnv

declare -r gccVersToUse=$("${TOOLCHAIN}"/bin/gcc -dumpversion)
declare -r ebuildToolchainFlag='gcc'$(echo "$gccVersToUse" | sed  's/\.//;s/\..*$//')

buildMess="*    Auto-Build Full Clover rEFIt_UEFI    *"
cleanMode=""
built="No"

makePKG "$target" # do complete build

echob "Good $hours."

# Local Variables:      #
# mode: ksh             #
# tab-width: 4          #
# indent-tabs-mode: nil #
# End:                  #
#
# vi: set expandtab ts=4 sw=4 sts=4: #
