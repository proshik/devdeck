# DevDeck — development and packaging tasks.
# Requires `just` (https://github.com/casey/just). List all recipes: `just --list`.

project := "DevDeck.xcodeproj"
scheme := "DevDeck"

# show the list of recipes
default:
    @just --list

# build and run a Debug build
run:
    xcodebuild build -project {{project}} -scheme {{scheme}} -configuration Debug -derivedDataPath build/dd
    open build/dd/Build/Products/Debug/{{scheme}}.app

# run unit tests
test:
    xcodebuild test -project {{project}} -scheme {{scheme}} -destination 'platform=macOS'

# build a Release build (unsigned)
build:
    xcodebuild build -project {{project}} -scheme {{scheme}} -configuration Release -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO

# package into a .dmg
dmg:
    ./scripts/build-dmg.sh

# remove build artifacts
clean:
    rm -rf build DerivedData
