#!/usr/bin/env bash
# Assemble simple stream metadata.
#
# Retrieve the published juju-core debs for a specific release.
# Extract the jujud from the packages.
# Generate the streams data.

set -eu

SCRIPT_DIR=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd )
SIGNING_PASSPHRASE_FILE=${SIGNING_PASSPHRASE_FILE:-}

# The location of environments.yaml and rc files.
JUJU_DIR=${JUJU_HOME:-$HOME/.juju}
JUJU_DIR=$(cd $JUJU_DIR; pwd)

# These are the archives that are search for matching releases.
UBUNTU_ARCH="http://archive.ubuntu.com/ubuntu/pool/universe/j/juju-core/"
ARM_ARCH="http://ports.ubuntu.com/pool/universe/j/juju-core/"
ALL_ARCHIVES="$UBUNTU_ARCH $ARM_ARCH"

if [[ -f $JUJU_DIR/buildarchrc ]]; then
    source $JUJU_DIR/buildarchrc
    echo "Adding the build archives to list of archives to search."
    ALL_ARCHIVES="$ALL_ARCHIVES $BUILD_STABLE_ARCH $BUILD_DEVEL_ARCH"
else
    echo "Only public archives will be searched."
fi


usage() {
    options="[-t TEST_DEBS_DIR]"
    echo "usage: $0 $options PURPOSE RELEASE STREAMS_DIRECTORY [SIGNING_KEY]"
    echo "  TEST_DEBS_DIR: The optional directory with testing debs."
    echo "  PURPOSE: testing, devel, proposed, released"
    echo "  RELEASE: The pattern (version) to match packages in the archives."
    echo "           Use IGNORE when you want to regenerate metadata without"
    echo "           downloading debs and extracting new tools."
    echo "  STREAMS_DIRECTORY: The directory to assemble the tools in."
    echo "  SIGNING_KEY: When provided, the metadata will be signed."
    exit 1
}


check_deps() {
    echo "Phase 0: Checking requirements."
    has_deps=1
    which lftp || has_deps=0
    if [[ GET_RELEASED_TOOL == "true" ]]; then
        which s3cmd || has_deps=0
        test -f $JUJU_DIR/s3cfg || has_deps=0
        test -f $JUJU_DIR/environments.yaml || has_deps=0
    fi
    if [[ $has_deps == 0 ]]; then
        echo "Install lftp, s3cmd, then configure s3cmd in JUJU_HOME."
        exit 2
    fi
}


build_tool_tree() {
    echo "Phase 1: Building collection and republication tree."
    if [[ ! -d $DEST_DEBS ]]; then
        mkdir $DEST_DEBS
    fi
    if [[ ! -d $DEST_DIST/tools/releases ]]; then
        mkdir -p $DEST_DIST/tools/releases
    fi
    if [[ ! -d $DEST_DIST/tools/streams/v1 ]]; then
        mkdir -p $DEST_DIST/tools/streams/v1
    fi
    if [[ ! -d $JUJU_DIST/tools/$PURPOSE ]]; then
        mkdir -p $JUJU_DIST/tools/$PURPOSE
    fi
}


sync_released_tools() {
    # Retrieve previously released tools to ensure the metadata continues
    # to work for historic releases.
    echo "Phase 2: Retrieving released tools."
    if [[ $PURPOSE == "released" ]]; then
        # The directory layout doesn't describe the released dir as "release".
        local source_dist="juju-dist"
    elif [[ $PURPOSE == "testing" ]]; then
        # The testing purpose copies from "proposed" because this stream
        # represents every version that can could be a stable release. Testing
        # is volatile, it is always proposed + new tools that might be
        # stable in the future.
        local source_dist="juju-dist/proposed"
    else
        # The devel and proposed purposes use their own dirs for continuity.
        local source_dist="juju-dist/$PURPOSE"
    fi
    s3cmd -c $JUJU_DIR/s3cfg sync \
        s3://$source_dist/tools/releases/ $DEST_DIST/tools/releases/
}


retract_tools() {
    echo "Phase 3: Reseting streams as needed."
    if [[ $PURPOSE == "testing" ]]; then
        echo "Removing all testing agents to reset for testing."
        local RETRACT_GLOB="juju-*.tgz"
    elif [[ -n "$REMOVE_RELEASE" ]]; then
        local RETRACT_GLOB="juju-$REMOVE_RELEASE*.tgz"
    else
        echo "Nothing to reset"
        return
    fi
    local deleted=$(
        find $DEST_DIST/tools/releases -name "$RETRACT_GLOB" -delete -print)
    if [[ -n $deleted  ]]; then
        REMOVED="--removed $REMOVE_RELEASE"
    fi
}


init_tools_maybe() {
    echo "Phase 4: Checking for $PURPOSE tools in the tree."
    count=$(find $DESTINATION/juju-dist/tools/releases -name '*.tgz' | wc -l)
    if [[ $((count)) == 0 && -d $DESTINATION/tools/releases ]]; then
        # Migrate the old release cache to the new cache in juju-dist/.
        cp $DESTINATION/tools/releases/*.tgz \
            $DESTINATION/juju-dist/tools/releases
    fi
    count=$(find $DESTINATION/juju-dist/tools/releases -name '*.tgz' | wc -l)
    if [[ $((count)) < 400  ]]; then
        echo "The tools in $DESTINATION/tools/releases looks incomplete"
        echo "Data will be lost if metadata is regenerated."
        exit 7
    fi
    count=$(find $DEST_DIST/tools/releases -name '*.tgz' | wc -l)
    if [[ $PURPOSE == "proposed" && $((count)) == 0 ]]; then
        echo "Seeding proposed with all released agents"
        cp $DESTINATION/juju-dist/tools/releases/juju-*.tgz \
            $DEST_DIST/tools/releases
    elif [[ $PURPOSE == "devel" && $INIT_VERSION != "" ]]; then
        echo "Seeding devel with $INIT_VERSION released agents"
        cp $DESTINATION/juju-dist/tools/releases/juju-$INIT_VERSION*.tgz \
            $DEST_DIST/tools/releases
    elif [[ $PURPOSE == "testing" && $((count)) < 16 ]]; then
        if [[ $IS_DEVEL_VERSION == "true" ]]; then
            echo "Seeding testing with all devel agents"
            cp $DESTINATION/juju-dist/devel/tools/releases/juju-*.tgz \
                $DEST_DIST/tools/releases
        fi
        echo "Seeding testing with all proposed agents"
        cp $DESTINATION/juju-dist/proposed/tools/releases/juju-*.tgz \
            $DEST_DIST/tools/releases
    fi
}


retrieve_packages() {
    # Retrieve the $RELEASE packages that contain jujud,
    # or copy a locally built package.
    echo "Phase 5: Retrieving juju-core packages from archives"
    if [[ $IS_TESTING == "true" ]]; then
        linked_files=$(
            find $TEST_DEBS_DIR -name 'juju-core_*.deb' -or -name 'juju-*.tgz')
        for linked_file in $linked_files; do
            # We need the real file location which includes series and arch.
            deb_file=$(readlink -f $linked_file)
            cp $deb_file $DEST_DEBS
        done
    else
        cd $DEST_DEBS
        for archive in $ALL_ARCHIVES; do
            safe_archive=$(echo "$archive" | sed -e 's,//.*@,//,')
            echo "checking $safe_archive for $RELEASE."
            lftp -c mirror -I "juju-core_${RELEASE}*.deb" $archive;
        done
        if [ -d $DEST_DEBS/juju-core ]; then
            found=$(find $DEST_DEBS/juju-core/ -name "*deb")
            if [[ $found != "" ]]; then
                mv $DEST_DEBS/juju-core/*deb ./
            fi
            rm -r $DEST_DEBS/juju-core
        fi
        if [[ -e $JUJU_DIR/juju-qa.s3cfg ]]; then
            echo "checking s3://juju-qa-data/win-agents for $RELEASE."
            $SCRIPT_DIR/win_agent_archive.py --config $JUJU_DIR/juju-qa.s3cfg \
                get $RELEASE $DEST_DEBS
        fi
    fi
}


get_version() {
    # Defines $version. $version can be different than $RELEASE used to
    # match the packages in the archives.
    control_version=$1
    version=$(echo "$control_version" | sed -r 's,-0ubuntu.*$,,;')
    if [ "${version}" == "" ] ; then
        echo "Invalid version: $control_version"
        exit 3
    fi
}


get_series() {
    # Defines $series.
    control_version=$1
    ubuntu_devel=$(grep DEVEL $SCRIPT_DIR/supported-releases.txt |
        cut -d ' ' -f 1)
    pkg_series=$(basename "$control_version" ~juju1 |
        sed -r "s/([0-9]ubuntu[0-9])$/\1~$ubuntu_devel/;" |
        sed -r "s/.*(ubuntu|~)([0-9][0-9]\.[0-9][0-9]).*/\2/")
    series=$(cat $SCRIPT_DIR/supported-releases.txt |
        grep $pkg_series | cut -d ' ' -f 2)
    if [[ -z $series ]]; then
        echo "Invalid series: $control_version, saw [$pkg_series]"
        exit 3
    fi
}


get_arch() {
    # Defines $arch.
    control_file=$1
    arch=$(sed -n 's/^Architecture: \([a-z]\+\)/\1/p' $control_file)
    case "${arch}" in
        "amd64" | "i386" | "armel" | "armhf" | "arm64" | "ppc64el" )
            # The ubuntu arch matches the juju arch.
            ;;
        *)
            echo "Invalid arch: $arch"
            arch="UNSUPPORTED"
            ;;
    esac
}


archive_extra_ppc64_tool() {
    # Hack to create ppc64 because it is not clear if juju wants
    # this name instead of ppc64el.
    tool="${DEST_DIST}/tools/releases/juju-${version}-${series}-ppc64.tgz"
    if [[ ! -e $tool ]]; then
        echo "Creating ppc64 from ppc64el: $tool"
        tar cvfz $tool -C $change_dir jujud
        added_tools[${#added_tools[@]}]="$tool"
        echo "Created ${tool}."
    fi
}


archive_tools() {
    # Builds the jujud tgz for each series and arch.
    echo "Phase 6: Extracting jujud from packages and archiving tools."
    cd $DESTINATION
    WORK=$(mktemp -d)
    mkdir ${WORK}/juju
    PACKAGES=$(find ${DEST_DEBS} -name "*.deb")
    for package in $PACKAGES; do
        echo "Extracting jujud from ${package}."
        dpkg-deb -e $package ${WORK}/juju
        control_file="${WORK}/juju/control"
        control_version=$(sed -n 's/^Version: \(.*\)/\1/p' $control_file)
        get_version $control_version
        get_series $control_version
        get_arch $control_file
        tool="${DEST_DIST}/tools/releases/juju-${version}-${series}-${arch}.tgz"
        if [[ $arch == 'UNSUPPORTED' ]]; then
            echo "Skipping unsupported architecture $package"
        elif [[ -e $tool ]]; then
            echo "Skipping $package because $tool already exists."
        else
            echo "Creating $tool."
            dpkg-deb -x $package ${WORK}/juju
            bin_dir="${WORK}/juju/usr/bin"
            lib_dir="${WORK}/juju/usr/lib/juju-${version}/bin"
            if [[ -f "${bin_dir}/jujud" ]]; then
                change_dir=$bin_dir
            elif [[ -f "${lib_dir}/jujud" ]]; then
                change_dir=$lib_dir
            else
                echo "jujud is not in /usr/bin or /usr/lib"
                exit 4
            fi
            sane_date=$(ar -tv ${package} |
                grep data.tar |
                cut -d ' ' -f4- |
                sed -e 's,\([^ ]*\) \+\(.*\) \(.*\) \(.*\) .*,\2 \1 \4,')
            touch --date="$sane_date" $change_dir/jujud
            tar cvfz $tool -C $change_dir jujud
            added_tools[${#added_tools[@]}]="$tool"
            echo "Created ${tool}."
            if [[ $arch == 'ppc64el' ]]; then
                archive_extra_ppc64_tool
            fi
        fi
        rm -r ${WORK}/juju/*
    done
    AGENTS=$(find $DEST_DEBS -name "juju-*.tgz")
    for agent in $AGENTS; do
        local agent_name=$(basename $agent)
        local dest_agent="$DEST_DIST/tools/releases/$agent_name"
        if [[ -e $dest_agent ]]; then
            echo "Skipping $agent_name because $dest_agent already exists."
        else
            cp $agent $dest_agent
            added_tools[${#added_tools[@]}]="$dest_agent"
        fi
    done
    # The extracted files are no longer needed. Clean them up now.
    rm -r $WORK
    if [[ -n "${added_tools[@]:-}" ]]; then
        ADDED="--added $RELEASE"
    else
        # Exit early when debs were searched, but no new tools were found.
        echo "No tools were added from the built debs."
        cleanup
        if [[ $IS_TESTING == "true" ]]; then
            echo "The branch version may be out of date; $RELEASE is published?"
            exit 5
        else
            echo "No new tools were found for $RELEASE, exiting early."
            echo "Use 'IGNORE' as the release version if you want to generate."
            echo "streams from tools in $DEST_DIST/tools/releases"
            exit 0
        fi
    fi
}


copy_proposed_to_release() {
    echo "Phase 6: Copying proposed tools to released."
    local proposed_releases="$DESTINATION/juju-dist/proposed/tools/releases"
    count=$(find $proposed_releases -name "juju-${RELEASE}*.tgz" | wc -l)
    if [[ $((count)) == 0  ]]; then
        echo "Proposed doesn't have any $RELEASE tools."
        echo "Tools cannot be released without first being proposed."
        exit 6
    fi
    cp $proposed_releases/juju-${RELEASE}*.tgz  $DEST_DIST/tools/releases
    ADDED="--added $RELEASE"
}


extract_new_juju() {
    # Extract a juju-core that was found in the archives to run metadata.
    # Match by release version and arch, prefer exact series, but fall back
    # to generic ubuntu.
    echo "Using juju from a downloaded deb."
    source /etc/lsb-release
    ARCH=$(dpkg --print-architecture)
    juju_cores=$(find $DEST_DEBS -name "juju-core_${RELEASE}*${ARCH}.deb")
    juju_core=$(echo "$juju_cores" | grep $DISTRIB_RELEASE | head -1)
    if [[ $juju_core == "" ]]; then
        juju_core=$(echo "$juju_cores" | head -1)
    fi
    dpkg-deb -x $juju_core $JUJU_PATH/
    JUJU_EXEC=$(find $JUJU_PATH -name 'juju' | grep bin/juju)
    JUJU_BIN_PATH=$(dirname $JUJU_EXEC)
}



generate_streams() {
    # Create the streams metadata and organised the tree for later publication.
    echo "Phase 7: Generating streams data."
    cd $DEST_DIST
    JUJU_PATH=$(mktemp -d)
    # Prefer the juju that matches the version being released.
    if [[ $RELEASE != "IGNORE" ]]; then
        extract_new_juju
    else
        JUJU_EXEC=$(which juju)
        JUJU_BIN_PATH=""
    fi
    juju_version=$($JUJU_EXEC --version)
    echo "Using juju: $juju_version"

    #
    # Old many-tree support.
    #
    # Backup the current json to old json if it exists for later validation.
    local can_validate="false"
    OLD_JSON="$DESTINATION/old-$PURPOSE.json"
    NEW_JSON="$DEST_DIST/tools/streams/v1/com.ubuntu.juju:released:tools.json"
    if [[ -f $NEW_JSON ]]; then
        cp $NEW_JSON $OLD_JSON
        local can_validate="true"
    fi

    # Alway delete the json because juju wont validate checksums if the
    # json exists.
    set -x
    find ${DEST_DIST}/tools/streams/v1/ -type f -delete
    # Generate the json metadata.
    JUJU_HOME=$JUJU_DIR PATH=$JUJU_BIN_PATH:$PATH \
        $JUJU_EXEC metadata generate-tools -d ${DEST_DIST}

    # Ensure the new json metadata matches the expected removed and added.
    if [[ $can_validate == "true" && $PURPOSE =~ ^(released|proposed)$ ]]; then
        $SCRIPT_DIR/validate_streams.py \
            $REMOVED $ADDED $PURPOSE $OLD_JSON $NEW_JSON
    fi
    set +x
    echo "The tools are in ${DEST_DIST}."

    #
    # New one-tree support.
    #
    if [[ $PURPOSE =~ ^(released|proposed|testing)$ ]]; then
        rm -r $JUJU_PATH
        return
    fi
    # XXX sinzui 2014-11-01: This cp step will be replaced when one-tree is
    # the default.
    if [[ $PURPOSE == "released" ]]; then
        # Juju 1.15* can see released streams.
        cp $DEST_DIST/tools/releases/juju-*.tgz $JUJU_DIST/tools/$PURPOSE/
    else
        # Only new juju 1.21* can see devel and proposed.
        local agents=$(
            find $DEST_DIST/tools/releases/ -name 'juju-1.2*' | sed -r /1.20/d)
        cp $agents $JUJU_DIST/tools/$PURPOSE/
    fi

    # Backup the current json to old json if it exists for later validation.
    local can_validate="false"
    local count=$(find $JUJU_DIST/tools/streams/v1 -name 'com*.json' | wc -l)
    if [[ $((count)) != 0 ]]; then
        cp $JUJU_DIST/tools/streams/v1/com*.json $DESTINATION/
        local can_validate="true"
    fi

    # Alway delete the product json because juju wont validate checksums
    # if the json exists. The mirror and signed data will be regenerated.
    # The index.json and the other product json files remain for
    # generate-tools to inspect.
    set -x
    find $JUJU_DIST/tools/streams/v1/ -name "*$PURPOSE:tools*" -delete -print
    find $JUJU_DIST/tools/streams/v1/ -name "*gpg" -delete -print
    find $JUJU_DIST/tools/streams/v1/ -name "*sjson" -delete -print
    find $JUJU_DIST/tools/streams/v1/ -name "*mirror*" -delete -print
    # Generate the json metadata.
    JUJU_HOME=$JUJU_DIR PATH=$JUJU_BIN_PATH:$PATH \
        $JUJU_EXEC metadata generate-tools \
        -d $JUJU_DIST --stream $PURPOSE
    rm -r $JUJU_PATH

    # Ensure the new json metadata matches the expected removed and added.
    if [[ $can_validate == "true" ]]; then
        old_product_files=$(ls $DESTINATION/com*.json)
        for old_product in $old_product_files; do
            local product_name=$(basename $old_product)
            local new_product="$JUJU_DIST/tools/streams/v1/$product_name"
            local old_purpose=$(echo "$product_name" |
                sed -r "s,.*:([^:]*):.*,\1,")
            if [[ $old_purpose =~ ^(released|proposed)$ ]]; then
                if [[ $old_purpose == $PURPOSE ]]; then
                    # Ensure the added and removed are correct.
                    $SCRIPT_DIR/validate_streams.py \
                        $REMOVED $ADDED $PURPOSE $old_product $new_product
                else
                    # No changes are permitted.
                    $SCRIPT_DIR/validate_streams.py \
                        $old_purpose $old_product $new_product
                fi
            else
                echo "! Manually inspect $new_product for expected changes."
            fi
        done
    fi
    set +x
    echo "The agents are in $JUJU_DIST."
}


generate_mirrors() {
    echo "Phase 8: Creating mirror json."
    ${SCRIPT_DIR}/generate_mirrors.py $DEST_DIST/tools/
    #
    # New one-tree support.
    #
    if [[ $PURPOSE =~ ^(released|proposed|testing)$ ]]; then
        return
    fi
    ${SCRIPT_DIR}/generate_mirrors.py $JUJU_DIST/tools/
}


sign_metadata() {
    echo "Phase 9: Signing metadata with $SIGNING_KEY."
    key_option="--default-key $SIGNING_KEY"
    gpg_options=""
    if [[ -n $SIGNING_PASSPHRASE_FILE ]]; then
        gpg_options="--no-use-agent --no-tty"
        gpg_options="$gpg_options --passphrase-file $SIGNING_PASSPHRASE_FILE"
    fi
    pattern='s/\(\.json\)/.sjson/'
    #
    # Old many-tree support.
    #
    meta_files=$(ls ${DEST_DIST}/tools/streams/v1/*.json)
    for meta_file in $meta_files; do
        signed_file=$(echo "$meta_file" | sed -e $pattern)
        echo "Creating $signed_file"
        echo "gpg $gpg_options --clearsign $key_option > $signed_file"
        sed -e $pattern $meta_file |
            gpg $gpg_options --clearsign $key_option > $signed_file
        echo "gpg $gpg_options --detach-sign $key_option > $meta_file.gpg"
        cat $meta_file |
            gpg $gpg_options --detach-sign $key_option > $meta_file.gpg
    done
    echo "The signed tools are in ${DEST_DIST}."

    #
    # New one-tree support.
    #
    if [[ $PURPOSE =~ ^(released|proposed|testing)$ ]]; then
        return
    fi
    meta_files=$(ls ${JUJU_DIST}/tools/streams/v1/*.json)
    for meta_file in $meta_files; do
        signed_file=$(echo "$meta_file" | sed -e $pattern)
        echo "Creating $signed_file"
        #echo "gpg $gpg_options --clearsign $key_option > $signed_file"
        sed -e $pattern $meta_file |
            gpg $gpg_options --clearsign $key_option > $signed_file
        #echo "gpg $gpg_options --detach-sign $key_option > $meta_file.gpg"
        cat $meta_file |
            gpg $gpg_options --detach-sign $key_option > $meta_file.gpg
    done
    echo "The signed tools are in $JUJU_DIST."
}


cleanup() {
    # Remove the debs and testing tools so that they are not reused in
    # future runs of the script.
    find ${DEST_DEBS} -name "*.deb" -delete
    find ${DEST_DEBS} -name "*.tgz" -delete
}


# Parse options and args.
REMOVE_RELEASE=""
SIGNING_KEY=""
IS_TESTING="false"
GET_RELEASED_TOOL="true"
INIT_VERSION="1.20"
while getopts "r:s:t:i:n" o; do
    case "${o}" in
        r)
            REMOVE_RELEASE=${OPTARG}
            echo "$REMOVE_RELEASE agents will be removed from the data."
            ;;
        s)
            SIGNING_KEY=${OPTARG}
            echo "The streams will be signed with $SIGNING_KEY"
            ;;
        t)
            TEST_DEBS_DIR=${OPTARG}
            [[ -d $TEST_DEBS_DIR ]] || usage
            IS_TESTING="true"
            echo "Assembling testing tools from $TEST_DEBS_DIR"
            ;;
        i)
            INIT_VERSION=${OPTARG}
            echo "Will init the stream with $INIT_VERSION."
            ;;
        n)
            GET_RELEASED_TOOL="false"
            echo "Not downloading release tools."
            ;;
        *)
            echo "Invalid option: ${o}"
            usage
            ;;
    esac
done
shift $((OPTIND - 1))
test $# -eq 3 || usage

PURPOSE=$1
if [[ ! $PURPOSE =~ ^(released|proposed|devel|testing)$ ]]; then
    echo "Invalid PURPOSE."
    usage
fi

RELEASE=$2
if [[ $RELEASE =~ ^.*[a-z]+.*$ ]]; then
    IS_DEVEL_VERSION="true"
else
    IS_DEVEL_VERSION="false"
fi
if [[ $IS_DEVEL_VERSION == "true" && $PURPOSE =~ ^(released|proposed)$ ]]; then
    echo "$RELEASE looks like a devel version."
    echo "$RELEASE cannot be proposed or released."
    exit 1
fi

DESTINATION=$3
if [[ ! -d "$3" ]]; then
    echo "$3 is not a directory. Create it if you really mean to use it."
    usage
else
    DESTINATION=$(cd $DESTINATION; pwd)
fi


# Configure paths, arch, and series
DEST_DEBS="${DESTINATION}/debs"
JUJU_DIST="$DESTINATION/juju-dist"
if [[ $PURPOSE == "released" ]]; then
    DEST_DIST="$DESTINATION/juju-dist"
else
    DEST_DIST="$DESTINATION/juju-dist/$PURPOSE"
fi
declare -a added_tools
added_tools=()
ADDED=""
REMOVED=""


# Main.
check_deps
build_tool_tree
if [[ $GET_RELEASED_TOOL == "true" ]]; then
    sync_released_tools
fi
retract_tools
init_tools_maybe
if [[ $RELEASE != "IGNORE" ]]; then
    retrieve_packages
    if [[ $PURPOSE == "released" ]]; then
        copy_proposed_to_release
    else
        archive_tools
    fi
fi
generate_streams
if [[ $SIGNING_KEY != "" ]]; then
    generate_mirrors
    sign_metadata
fi
cleanup
