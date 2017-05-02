# PTJD, a pure Tcl (baseline) JPEG decoder.
# Copyright (c) 2017 dbohdan and contributors listed in AUTHORS
# License: MIT.
source ptjd.tcl

set iterations 5
set debugChan stdout

proc read-test-file filename {
    set h [open [file join test-data $filename] rb]
    set result [read $h]
    close $h
    return $result
}

proc engine {} {
    if {[info exists ::tcl_platform(engine)]} {
        return $::tcl_platform(engine)
    } elseif {[string match 8.* [info patchlevel]]} {
        return Tcl
    } elseif {![catch {
            proc foo {} {{bar 0}} {}; info statics foo; rename foo {}
        }]} {
        return Jim
    } else {
        return Unknown
    }
}

proc main {} {
    set files [list grayscale.jpg landscape.jpg landscape-q.jpg]
    puts $::debugChan "Running on [engine] [info patchlevel]"
    puts $::debugChan "$::iterations iterations per image"
    puts $::debugChan ==========================
    foreach filename $files {
        set image [read-test-file $filename]
        lassign [time {::ptjd::decode $image} $::iterations] microseconds
        puts $::debugChan [format {%-16s %6i ms} \
                                  $filename \
                                  [expr {round($microseconds/1000)}]]
    }
}

main
