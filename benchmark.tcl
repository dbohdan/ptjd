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

proc main {} {
    set files [list grayscale.jpg landscape.jpg landscape-q.jpg]
    puts $::debugChan "$::iterations iterations per image"
    foreach filename $files {
        set image [read-test-file $filename]
        lassign [time {::ptjd::decode $image} $::iterations] microseconds
        puts $::debugChan "$filename: [expr {round($microseconds/1000)}] ms"
    }
}

main
