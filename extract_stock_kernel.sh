#!/usr/bin/bash

# This script extracts kernel files downloaded from Samsung Open Source, extracts them into /tmp and merge them into a git repo
#
# Copyright (C) 2021 Javier Ferrer

#   This program is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.

#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.

#   You should have received a copy of the GNU General Public License
#   along with this program.  If not, see <http://www.gnu.org/licenses/>.



# These variables are filled with arguments coming from outside world
DEST_DIR=
SRC_FILE=
JOB_NO=8


# These variables are filled in this script

# Source code version, extracted from source file name
SRC_VERSION=

# Device model, extracted from source file name. Example: SM-G950F for Galaxy S8 exynos
DEV_MODEL=

# Device name, extracted from DEV_MODEL. Example: G950F
DEV_NAME=

# Android version, extracted from source file name. Example: PP for Android Pie
ANDROID_VERSION=

TMP_DIR=
KERNEL_SRC_DIR=
KERNEL_VERSION=
KERNEL_PATCHLEVEL=
KERNEL_SUBLEVEL=
KERNEL_VERSION_STR=
DEST_DIR_EMPTY=
DEST_DIR_HAS_REPO=
DEST_DIR_REPO_IS_CLEAN=
PERMISSION_2_FIX_AUX=
SAMMY_KERNEL_MERGED=
SAMMY_LAST_VER=


function cleanup_tmp(){
    if [ ! -z "$TMP_DIR" ]; then
        rm -rf $TMP_DIR
    fi
}
trap cleanup_tmp EXIT


function show_usage (){
    echo "Usage: $0 [OPTION]"
    echo ""
    echo " -d|--dest DIR           Destination directory. If it is empty, it will be created and initialized."
    echo " -s|--src FILE           File name of zip file downloaded from opensource.samsung.com . Use following naming convention:"
    echo "                           [PREFIX]_[VERSION].zip - The VERSION will be extracted from the file name and will be used to create the commits."
    echo "                           Example: SM-G950F_PP_Opensource_G950FXXS7DTA6.zip"
    echo "                           The source file will be extracted in a temp directory and its contents will be copied into destination directory,"
    echo "                           then a cleanup will be performed."
    echo " -j|--jobs JOBS          Specifies the number of jobs for fixing permissions."
    echo " -h|--help               Print help"

    return 0
}


function parse_src_file_name(){
    # Samsung files are usually named 'SM-G950F_PP_Opensource.zip' but we request our users to append the version before the zip extension.
    # So we expect the file to be named so: SM-G950F_PP_Opensource_G950FXXS7DTA6.zip

    # Separate path from SRC_FILE
    local src_file_name=${SRC_FILE##*/}

    local old_IFS=$IFS
    IFS='_'
    local src_file_token=( $src_file_name )
    #echo "0=${src_file_token[0]} 1=${src_file_token[1]} 2=${src_file_token[2]} 3=${src_file_token[3]}"

    # Consistency check
    if [ "${src_file_token[2]}" != "Opensource" ]; then
        echo "parse_src_file_name: File name mismatch!"
        exit 1
    fi

    SRC_VERSION=${src_file_token[3]%.*}
    DEV_MODEL=${src_file_token[0]}
    DEV_NAME=${DEV_MODEL:3}
    ANDROID_VERSION=${src_file_token[1]}
    echo "SRC_VERSION=$SRC_VERSION DEV_MODEL=$DEV_MODEL DEV_NAME=$DEV_NAME ANDROID_VERSION=$ANDROID_VERSION"

    # restore IFS
    IFS=$old_IFS
}


function extract_kernel_version(){
    local MAKEFILE=$KERNEL_SRC_DIR/Makefile

    if [ ! -f "$MAKEFILE" ]; then
        echo "'$MAKEFILE' not found"
        exit 1
    fi

    local kernel_ver_aux=`cat $MAKEFILE | grep "SUBLEVEL = " -B2`
    #echo "kernel_ver_aux=$kernel_ver_aux"
    local kernel_ver_token=( $kernel_ver_aux )

    KERNEL_VERSION=${kernel_ver_token[2]}
    KERNEL_PATCHLEVEL=${kernel_ver_token[5]}
    KERNEL_SUBLEVEL=${kernel_ver_token[8]}

    KERNEL_VERSION_STR=$KERNEL_VERSION.$KERNEL_PATCHLEVEL

    #echo "KERNEL_SUBLEVEL=$KERNEL_SUBLEVEL   KERNEL_VERSION_STR=$KERNEL_VERSION_STR"
}


# Function extract_src() extract sources in /tmp , searches for kernel version and places it into ...
function extract_src (){
    TMP_DIR=`mktemp -d -t sammy-XXX`

    echo "Creating temp dir '$TMP_DIR'"

    cd $TMP_DIR
    echo "Uncompressing '$SRC_FILE'"
    unzip $SRC_FILE 1>/dev/null

    UNZIP_RC=$?

    if [ "$UNZIP_RC" != "0" ]; then
        echo "rc of unzip: $UNZIP_RC"
        exit 1
    fi

    #ls $TMP_DIR

    #Now search for Kernel.tar.gz in the extracted files
    KERNEL_TGZ="$TMP_DIR/Kernel.tar.gz"

    if [ ! -f "$KERNEL_TGZ" ]; then
        echo "Kernel.tar.gz not found in uncompressed source file 'SRC_FILE'"
        exit 1
    fi

    KERNEL_SRC_DIR=$TMP_DIR/kernel_src
    mkdir $KERNEL_SRC_DIR
    cd $KERNEL_SRC_DIR
    tar -zxvf $KERNEL_TGZ 1>/dev/null

    TAR_RC=$?

    if [ "$TAR_RC" != "0" ]; then
        echo "rc of tar: $TAR_RC"
        exit 1
    fi

    #echo "KERNEL_SRC_DIR='$KERNEL_SRC_DIR'"
    #ls $KERNEL_SRC_DIR

    echo "Searching for kernel version..."
    extract_kernel_version
}


function kernel_src_cleanup(){
    rm -rf $KERNEL_SRC_DIR/toolchain
}


function check_args(){
    if [ -z "$DEST_DIR" ]; then
        echo "Destination directory not specified."
        show_usage
        exit 1
    fi

    if [ ! -d "$DEST_DIR" ]; then
        echo "Destination directory '$DEST_DIR' doesn't exist. Create it."
        mkdir $DEST_DIR
    fi

    if [ -z "$SRC_FILE" ]; then
        echo "Source file not specified."
        show_usage
        exit 1
    fi

    if [ ! -f "$SRC_FILE" ]; then
        echo "Source file '$SRC_FILE' doesn't exist."
        exit 1
    fi

    case $JOB_NO in
        ''|*[!0-9]*)
            echo "Bad number of jobs! Taking 1 as default!"
            JOB_NO=1
            ;;
        *) ;;
    esac
}


function parse_args(){
    while [ ! -z "$1" ]; do
        #echo "parse_args: parsing $1"

        case "$1" in
        --dest|-d)
            shift
            DEST_DIR=$1
            ;;

        --src|-s)
            shift
            SRC_FILE=$1
            ;;

        --jobs|-j)
            shift
            JOB_NO=$1
            ;;

        *)
            show_usage
            exit 0
            ;;
        esac

        shift
    done
}


function dest_dir_is_empty(){
    local ls_out=$(ls -A $DEST_DIR)
    # echo "ls_out=$ls_out"
    if [ -z "$ls_out" ]; then
        DEST_DIR_EMPTY=true
        # echo "DEST_DIR is empty"
    else
        DEST_DIR_EMPTY=false
        # echo "DEST_DIR is not empty"
    fi
}


function clone_upstream_kernel(){
    local kernel_branch=linux-$KERNEL_VERSION_STR.y

    #echo "kernel_branch=$kernel_branch"
    git clone -b $kernel_branch --single-branch https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git $DEST_DIR
}


function clone_android_kernel(){
    local suffix=

    case "$ANDROID_VERSION" in
        OO)
            suffix="o"
            ;;
        PP)
            suffix="p"
            ;;

        QQ)
            suffix="q"
            ;;

        RR)
            suffix="stable"
            ;;

        *)
            echo "clone_android_kernel: unrecognized ANDROID_VERSION='$ANDROID_VERSION'"
            exit 1
            ;;
    esac

    local kernel_branch=android-$KERNEL_VERSION_STR-$suffix

    #echo "kernel_branch=$kernel_branch"
    git clone -b $kernel_branch --single-branch https://android.googlesource.com/kernel/common $DEST_DIR
}


function detect_git_repo(){
    cd $DEST_DIR

    if git rev-parse --git-dir > /dev/null 2>&1; then
        echo "git repo found in '$DEST_DIR'"
        DEST_DIR_HAS_REPO=true

        local git_stat=`git status --porcelain`

        if [ -z "$git_stat" ]; then
            echo "git repo is clean"
            DEST_DIR_REPO_IS_CLEAN=true
        else
            echo "There are uncommited changes in '$DEST_DIR', exiting"
            exit 1
        fi
    else
        echo "git repo not found in '$DEST_DIR', exiting"
        DEST_DIR_HAS_REPO=false
        exit 1
    fi
}


function check_4_sammy_kernel_merged(){
    cd $DEST_DIR
    local sammy_there=$(git branch | grep $DEV_NAME | cut -c 3- | sort -r -k1.10)
    local sammy_ver_token=( $sammy_there )
    SAMMY_LAST_VER=${sammy_ver_token[0]}

    echo "SAMMY_LAST_VER=$SAMMY_LAST_VER"
    if [ -z "$SAMMY_LAST_VER" ]; then
        SAMMY_KERNEL_MERGED=false
    else
        SAMMY_KERNEL_MERGED=true
    fi
}


function git_work_linux(){
    detect_git_repo

    if [ "$DEST_DIR_HAS_REPO" = true ] && [ "$DEST_DIR_REPO_IS_CLEAN" = true ]; then
        # Check whether we've already merged Sammy code before
        check_4_sammy_kernel_merged

        cd $DEST_DIR

        echo "SAMMY_KERNEL_MERGED=$SAMMY_KERNEL_MERGED"
        if [ "$SAMMY_KERNEL_MERGED" = false ]; then
            # Checkout to same tag as kernel version has and create a branch for this sammy version
            git checkout -b $SRC_VERSION v$KERNEL_VERSION.$KERNEL_PATCHLEVEL.$KERNEL_SUBLEVEL
        else
            # Just create a branch on top of last sammy version
            git checkout $SAMMY_LAST_VER
            git checkout -b $SRC_VERSION
        fi

        # remove things from KERNEL_SRC_DIR (like toolchain) that we don't want to copy to our kernel repo
        kernel_src_cleanup

        rm -rf $DEST_DIR/*
        cp -R $KERNEL_SRC_DIR/* $DEST_DIR

        git add *

        local git_commit_out=$(git commit -m "Merge $SRC_VERSION")

        PERMISSION_2_FIX_AUX=$(echo "$git_commit_out" | grep "mode change")
        #echo "PERMISSION_2_FIX_AUX=$PERMISSION_2_FIX_AUX"
        #echo "git_commit_out=$git_commit_out"
    fi
}


function git_work_android(){
    detect_git_repo

    if [ "$DEST_DIR_HAS_REPO" = true ] && [ "$DEST_DIR_REPO_IS_CLEAN" = true ]; then
        # Check whether we've already merged Sammy code before
        check_4_sammy_kernel_merged

        cd $DEST_DIR

        echo "SAMMY_KERNEL_MERGED=$SAMMY_KERNEL_MERGED"
        if [ "$SAMMY_KERNEL_MERGED" = false ]; then
            # Search for commit with same kernel version
            local log_out=$(git log --oneline | grep "Merge.*$KERNEL_VERSION.$KERNEL_PATCHLEVEL.$KERNEL_SUBLEVEL.*into")
            local log_out_token=( $log_out )
            local commit=${log_out_token[0]}

            if [ -z commit ]; then
                echo "git_work_android: No commit found for $KERNEL_VERSION.$KERNEL_PATCHLEVEL.$KERNEL_SUBLEVEL"
                exit 1
            fi

            # Checkout to same tag as kernel version has and create a branch for this sammy version
            git checkout $commit
            git checkout -b $SRC_VERSION
        else
            # Just create a branch on top of last sammy version
            git checkout $SAMMY_LAST_VER
            git checkout -b $SRC_VERSION
        fi

        # remove things from KERNEL_SRC_DIR (like toolchain) that we don't want to copy to our kernel repo
        kernel_src_cleanup

        rm -rf $DEST_DIR/*
        cp -R $KERNEL_SRC_DIR/* $DEST_DIR

        git add *

        local git_commit_out=$(git commit -m "Merge $SRC_VERSION")

        PERMISSION_2_FIX_AUX=$(echo "$git_commit_out" | grep "mode change")
        #echo "PERMISSION_2_FIX_AUX=$PERMISSION_2_FIX_AUX"
        #echo "git_commit_out=$git_commit_out"
    fi
}


PERM_TOKENS_PER_LINE=6

function fix_permissions(){
    if [ ! -z PERMISSION_2_FIX_AUX ]; then
        cd $DEST_DIR

        local perm_token=( $PERMISSION_2_FIX_AUX )
        local progress=0

        for (( n=0; n < ${#perm_token[*]}; n=n+$PERM_TOKENS_PER_LINE))
        do
            local file=${perm_token[n+5]}
            local perm=${perm_token[n+2]:3}
            #echo "file=$file perm=$perm"

            if [ -f "$file" ]; then
                chmod $perm $file
                local perm_changed=true
            else
                # Found following git commit output from git_work()
                # mode change 100644 => 100755 net/ncm/Kconfig
                # mode change 100644 => 100755 net/ncm/Makefile
                # rewrite net/ncm/ncm.c (86%)
                # mode change 100644 => 100755
                # mode change 100644 => 100755 net/netfilter/Kconfig
                # mode change 100644 => 100755 net/netfilter/Makefile

                # So we should recover the n value and continue
                if [ "${perm_token[n]}" = "mode" ] && 
                   [ "${perm_token[n+1]}" = "change" ] && 
                   [ "${perm_token[n+3]}" = "=>" ] && 
                   [ "$file" = "mode" ]; then
                    ((--n))
                    continue
                fi
            fi

            progress=$(( n * 100 / ${#perm_token[*]} ))
            echo -ne "Fixing permissions: $progress%"\\r
        done

        echo "Fixing permisions: done"

        if [ "$perm_changed" = true ]; then
            echo "Merging permission restoration"
            git commit -a --amend -m "Merge $SRC_VERSION"
        fi
    fi
}


function align(){
    local value=$1
    local base=$2
    local result=$(( ((($value) + (($base) - 1)) & ~(($base) - 1)) ))
    return $result
}


function fix_permissions_parallel(){
    local first_token=$1
    local first_token_orig=$1
    local last_token=$2

    if (( $first_token > $PERM_TOKENS_PER_LINE )); then
        first_token=$(( $first_token - $PERM_TOKENS_PER_LINE )) #allow overlapping to not miss some file
    fi

    #adjust line begin
    for (( n=$first_token; (n < $last_token) && (n < ${#perm_token[*]} ) ; n=n+1))
    do
        #echo "parallel: perm_token[$n]=${perm_token[n]}"
        if [ "${perm_token[n]}" = "mode" ]; then
            break;
        fi
    done
    first_token=$n

    #echo "parallel: first_token=$first_token($first_token_orig) last_token=$last_token"

    for (( n=$first_token; (n < $last_token) && (n < ${#perm_token[*]} ) ; n=n+$PERM_TOKENS_PER_LINE))
    do
        local file=${perm_token[n+5]}
        local perm=${perm_token[n+2]:3}
        #echo "file=$file perm=$perm"

        if [ -f "$file" ]; then
            chmod $perm $file
        else
            # Found following git commit output from git_work()
            # mode change 100644 => 100755 net/ncm/Kconfig
            # mode change 100644 => 100755 net/ncm/Makefile
            # rewrite net/ncm/ncm.c (86%)
            # mode change 100644 => 100755
            # mode change 100644 => 100755 net/netfilter/Kconfig
            # mode change 100644 => 100755 net/netfilter/Makefile

            # So we should recover the n value and continue
            if [ "${perm_token[n]}" = "mode" ] && 
               [ "${perm_token[n+1]}" = "change" ] && 
               [ "${perm_token[n+3]}" = "=>" ] && 
               [ "$file" = "mode" ]; then
                ((--n))
                continue
            fi
        fi

        local progress=$(( n * 100 / ${#perm_token[*]} ))
        echo -ne "Fixing permissions: $progress%"\\r
    done
}


function fix_permissions_start(){
    if [ ! -z PERMISSION_2_FIX_AUX ]; then
        cd $DEST_DIR

        local perm_token=( $PERMISSION_2_FIX_AUX )
        local progress=0

        # Don't run in parallel when it is not worth
        if (( ${#perm_token[*]} <= (20 * $PERM_TOKENS_PER_LINE) )); then
            fix_permissions
            return
        fi

        # divide number of tokens into JOB_NO*2 parts, in order to be able to report some progress
        local pkg_size=0
        pkg_size=$(( ( ${#perm_token[*]} / ($JOB_NO*2) ) + 1 ))
        echo "number of tokens=${#perm_token[*]} pkg_size=$pkg_size"

        local first_token=0

        local started_jobs=0

        for (( i=0; i < ($JOB_NO*2); i=i+1 ))
        do
            local last_token=$(( $first_token + $pkg_size - 1 ))
            #echo "i=$i first_token=$first_token last_token=$last_token"

            # start parallel task
            fix_permissions_parallel $first_token $last_token &
            started_jobs=$(( $started_jobs + 1 ))

            if (( $started_jobs == $JOB_NO )); then
                echo "waiting for now..."
                wait
                echo "continuing..."
            fi

            first_token=$(( $last_token + 1 ))
        done

        wait
        echo "Fixing permisions: done"

#       TODO: check git status output
            echo "Merging permission restoration"
            git commit -a --amend -m "Merge $SRC_VERSION"
    fi
}


parse_args "$@"
check_args "$@"
parse_src_file_name
extract_src
dest_dir_is_empty

if [ "$DEST_DIR_EMPTY" = true ]; then
    clone_android_kernel
fi

git_work_android

fix_permissions_start
