#!/bin/bash

set -e # exit on error

readonly DEFAULT_IFS=$' \t\n'

# checks if a command is available
function check_prerequisite() {
    COMMAND=$1
    if ! command -v "$COMMAND" &> /dev/null; then
        echo "'$COMMAND' is required but could not be found. Please install it and make sure it's available."
        exit
    fi
}

# renders a note as html
function render_note() {
    INPUT_PATH="$1"
    OUTPUT_PATH="$2"
    FILENAME="${INPUT_PATH##*/}"
    TITLE="${FILENAME%.md}"

    pandoc --toc --standalone --metadata title="$TITLE" --css "$BASE_DIR/pandoc.css"  --lua-filter="$BASE_DIR/links-to-html.lua" --output "$OUTPUT_PATH" "$INPUT_PATH" 
}

# joins to paths and handle the case where  the first path is empty
# use whenever the first path can be empty (e.g. if it is a relative
# path in the root directory of the notes.
#
# a naive solution like "$1/$2" would result in an absolute path if
# the $1 was empty.
function concat_rel_paths() {
    if [[ -n "$1" ]]; then
        echo "$1/$2"
    else
        echo "$2"
    fi
}

function notes() {
    SEARCH_REGEX=".*" # default to everything
    QUERY="" # Start with no query
    FZF_HEADER=() # default to no header

    # Go into the notes directory to show only relative paths
    pushd "$NOTES_DIR" > /dev/null

    # Show interactive list and evaluate commands in a loop until the user decides to exit
    while true; do

        # Show list of note entries to choose from
        RESULT_STR=$(grep --recursive --ignore-case --files-with-matches --include '*.md' "$SEARCH_REGEX" . | sed 's/^.\///' | sort | fzf "${FZF_STYLING[@]}" "${FZF_BINDING[@]}" "${FZF_HEADER[@]}" --query="$QUERY" --history="$BASE_DIR"/search_history --expect=esc,enter,alt-enter,f1,ctrl-c,ctrl-s,ctrl-/,ctrl-t,ctrl-a --preview "bat ${BAT_STYLING[*]} {}")

        # Using `readarray` to split the results would be nicer but it is not supported in the older OSX bash
        COMMAND=$(head -1 <<< "$RESULT_STR")
        NOTE_REL_PATH=$(head -2 <<< "$RESULT_STR" | tail -1)

        # Extract relative directory in which the currently selected note resides
        NOTE_REL_DIR="" # Default to the root of the notes directory
        if [[ $NOTE_REL_PATH == */* ]]; then
            # Only if the selected note file is in a subdir, use the same subdir as destination for the new note
            NOTE_REL_DIR=${NOTE_REL_PATH%/*}
        fi

        NOTE_FILENAME=${NOTE_REL_PATH##*/}  # Strip path, leave only filename 
        NOTE_TITLE=${NOTE_FILENAME%.md} # String extension, leave only the title
        NOTE_ABS_PATH="$NOTES_DIR/$NOTE_REL_PATH"
        ATTACHMENT_REL_DIR="${NOTE_TITLE}_attachments"
        ATTACHMENT_ABS_DIR="$NOTES_DIR/$(concat_rel_paths "$NOTE_REL_DIR" "$ATTACHMENT_REL_DIR")"

        if [[ $COMMAND == esc ]]; then
            ########
            # Quit #
            ########

            # Revert back to original directory
            popd > /dev/null
            return
        elif [[ $COMMAND == enter ]]; then
            #############
            # Edit note #
            #############

            if [[ -n "${NOTE_REL_PATH}" ]]; then
                vim "$NOTE_REL_PATH"
            else
                echo "File not found"
                exit 4 # File not found for some unknown reason
            fi

            QUERY="$NOTE_REL_PATH"

        elif [[ $COMMAND == alt-enter ]]; then
            ###############
            # Render note #
            ###############

            if [[ -n "${NOTE_REL_PATH}" ]]; then
                HTML_ABS_PATH="${NOTE_ABS_PATH%.md}.html"
                render_note "$NOTE_ABS_PATH" "$HTML_ABS_PATH"
                open "$HTML_ABS_PATH"
            else
                echo "File not found"
                exit 4 # File not found for some unknown reason
            fi

            QUERY="$NOTE_REL_PATH"

        elif [[ $COMMAND == ctrl-c ]]; then
            ###############
            # Create note #
            ###############

            function read_title() {
                read -p "Note title [leave empty to exit]: " -r NEW_NOTE_TITLE
                NEW_NOTE_REL_PATH="$(concat_rel_paths "$NOTE_REL_DIR" "${NEW_NOTE_TITLE}.md")"
            }

            read_title
            while [[ -e "$NEW_NOTE_REL_PATH" ]]; do
                echo "'$NEW_NOTE_REL_PATH' already exists, try again."
                read_title
            done

            if [[ -z "$NEW_NOTE_TITLE" ]]; then
                continue # empty input means exit
            fi

            vim -c "set filetype=markdown | startinsert | edit $NEW_NOTE_REL_PATH | exec \"normal! i# $NEW_NOTE_TITLE\<cr>\<cr>\""

            QUERY="$NEW_NOTE_REL_PATH"

        elif [[ $COMMAND == ctrl-s ]]; then
            ###############
            # Open shell  #
            ###############

            pushd "$NOTE_REL_DIR" > /dev/null
            # Open bash with special command prompt so we know where we are
            bash --rcfile <(cat ~/.bashrc; echo "PS1=\"$BASH_PS1\"")
            popd > /dev/null

        elif [[ $COMMAND == ctrl-/ ]]; then
            ##########
            # Search #
            ##########

            read -r -p "Search RegEx: " SEARCH_REGEX
            if [[ -n "$SEARCH_REGEX" ]]; then
                FZF_HEADER=("--header=Search Regex: $SEARCH_REGEX")
            else
                FZF_HEADER=()
                SEARCH_REGEX=".*"
            fi

        elif [[ $COMMAND == ctrl-t ]]; then
            ###################
            # Today's journal #
            ###################

            journal

        elif [[ $COMMAND == ctrl-a ]]; then
            ################
            # Attach files #
            ################

            function read_dir() {
                # I would've preferred to use '-i' to set the initial text instead of putting the 
                # default in the prompt but unfotunately that's not supported in OSX's version of
                # bash (3.2.57)
                read -r -e -p "Source directory [default: $DEFAULT_ATTACHMENTS_DIR]: " SOURCE_DIR
                if [[ -z "$SOURCE_DIR" ]]; then
                    SOURCE_DIR="$DEFAULT_ATTACHMENTS_DIR"
                fi
            }

            # Ask for the source directory
            read_dir
            while [[ ! -d "$SOURCE_DIR" ]]; do
                echo "'$SOURCE_DIR' is not a directory, try again."
                read_dir
            done

            # Select files to attach from source directory
            ATTACH_FILES=$(find "$SOURCE_DIR" -depth 1 -type f | fzf "${FZF_STYLING[@]}" --header "tab: select multiple files | enter: attach files | esc: exit" --multi)

            # Loop over every file, copy it into the attachment directory and add a link to the note
            if [[ -n "$ATTACH_FILES" ]]; then
                mkdir -p "$ATTACHMENT_ABS_DIR"
                IFS=$'\n' 
                for i in $ATTACH_FILES; do
                    FILENAME=${i##*/}
                    ATTACHMENT_REL_PATH="$ATTACHMENT_REL_DIR/$FILENAME"

                    cp "$i" "$ATTACHMENT_ABS_DIR"

                    # add link to note file
                    EXTENSION="$(echo "${FILENAME##*.}" | tr '[:upper:]' '[:lower:]')" # lower case extension
                    IMAGE_INDICATOR="" # pandoc renders an image if prefixed with '!'
                    if [[ "$EXTENSION" == 'png' || "$EXTENSION" == 'jpg' || "$EXTENSION" == 'jpeg' || "$EXTENSION" == 'gif' || "$EXTENSION" == 'svg' ]]; then
                        IMAGE_INDICATOR="!"
                    fi
                    echo "${IMAGE_INDICATOR}[$FILENAME]($ATTACHMENT_REL_PATH)" >> "$NOTE_ABS_PATH"
                done
                IFS="$DEFAULT_IFS"
                echo "" >> "$NOTE_ABS_PATH" # another newline, looks nicer
            fi

            QUERY="$NOTE_REL_PATH"

        elif [[ $COMMAND == f1 ]]; then
            ########
            # Help #
            ########

            display_help "notes"
            echo ""
            read -r -p "Press enter to continue"
        else
           echo "Unknown command"
           exit 3 # Unknown command
        fi
    done
}

function html() {
    while IFS= read -r -d '' NOTE_ABS_PATH; do
        HTML_ABS_PATH="${NOTE_ABS_PATH%.md}.html"
        NOTE_REL_PATH="${NOTE_ABS_PATH#$NOTES_DIR}"
        
        if [[ "$NOTE_ABS_PATH" -nt "$HTML_ABS_PATH" ]]; then
            echo "Rendering '$NOTE_REL_PATH'"
            render_note "$NOTE_ABS_PATH" "$HTML_ABS_PATH"
        else
            echo "Skipping '$NOTE_REL_PATH' (already up-to-date)"
        fi
    done < <(find "$NOTES_DIR" -type f -name '*.md' -print0)
}

function journal() {
    TODAYS_FILE="$JOURNAL_DIR/$(date +%Y-%m-%d).md"
    TITLE="# $(date +%d/%m/%Y)"

    if [[ ! -f "$TODAYS_FILE" ]]; then
        echo "$TITLE" > "$TODAYS_FILE"
    fi

    vim "$TODAYS_FILE"
}

function display_help() {
    PARAMETER=$1

    case "$PARAMETER" in
    notes)
        echo "This command is used to manage note entries. It will display   "
        echo "an interactive list of note entries to choose from.            "
        echo ""
        echo "Usage:"
        echo "  $0 notes"
        echo ""
        echo "Shortcuts:"
        echo "  f1:         Show help"
        echo "  enter:      Edit note"
        echo "  esc:        Exit"
        echo ""
        echo "  ctrl-/:     Fulltext search"
        echo "  ctrl-n:     Create note"
        echo "  ctrl-t:     Create or open today's journal entry"
        echo "  ctrl-s:     Open shell in note directory"
        echo ""
        echo "  alt-bspace: Clear query" 
        echo ""
        echo "  ctrl-j:     Scroll note entry down"
        echo "  ctrl-k:     Scroll note entry up"
        echo "  ctrl-f:     Page note entry down"
        echo "  ctrl-b:     Page note entry up"
        echo ""
        echo "  ctrl-n:     Next from history"
        echo "  ctrl-p:     Prev from history"
        echo ""
        echo "Notes directory: $NOTES_DIR"
        ;;
    journal)
        echo "This command opens a special note with the current date as the title in the"
        echo "journal directory. If the note doesn't exist it will be created."
        echo ""
        echo "This the same as hitting 'ctrl-t' in the interactive notes list."
        echo ""
        echo "Usage:"
        echo "  $0 journal"
        echo ""
        echo "Journal directory: $JOURNAL_DIR"
        ;;
    html)
        echo "This command renders all notes as html files. If a corresponding html file "
        echo "already exists, it will compare the notes file timestamp to the timestamp  "
        echo "of the rendered html file. It will only re-render the file if the notes    "
        echo "file is newer."
        echo ""
        echo "This is similar to hitting 'alt-enter' in the interactive notes list       "
        echo "however it renders all files, not just one."
        echo ""
        echo "Usage:"
        echo "  $0 html"
        echo ""
        ;;
    *)
        echo "A tool to manage notes and journal entries"
        echo ""
        echo "Usage:"
        echo "  $0 <command>"
        echo ""
        echo "Available Commands:"
        echo "  help        Help about any command"
        echo "  notes       List, search, show, edit and create notes"
        echo "  journal     Opens today's journal note"
        echo "  html        Renders all notes as html files"
        echo ""
        echo "Use $0 help <command> for more information about a command."
        echo ""
        echo "Notes directory: $NOTES_DIR"
        ;;
    esac
}

################
# main section #
################

# Check if there is at least one parameter
if [ $# -lt 1 ]; then
    display_help
    exit
fi

# Check if needed commands are available
check_prerequisite "bat"
check_prerequisite "pandoc"
check_prerequisite "fzf"
check_prerequisite "vim"

# Read config if file exists
CONFIG="$HOME/.notes/notes.config"
# see: https://github.com/koalaman/shellcheck/wiki/SC1090
# shellcheck source=/dev/null
[[ -a $CONFIG ]] && source "$CONFIG"

# Set defaults if not set by config 
BASE_DIR=${BASE_DIR:-$HOME/.notes/}
NOTES_DIR=${NOTES_DIR:-$BASE_DIR/notes/}
JOURNAL_DIR=${JOURNAL_DIR:-$NOTES_DIR/journal/}
DEFAULT_ATTACHMENTS_DIR="$HOME/Downloads"
FZF_STYLING=('--border' '--margin=1' '--info=hidden')
FZF_BINDING=('--bind=ctrl-j:preview-down,ctrl-k:preview-up,ctrl-f:preview-page-down,ctrl-b:preview-page-up,alt-bspace:clear-query')
BAT_STYLING=('--color=always' '--language=markdown' '--plain')
BASH_PS1='\w [notes.sh]$ '

COMMAND=$1
PARAMETER=$2

case "$COMMAND" in
notes)
    notes
    ;;
journal)
    journal
    ;;
html)
    html
    ;;
help)
    display_help "$PARAMETER"
    ;;
*) 
    echo "Unknown command: $1"
    exit 1
    ;;
esac

