# PTJD, a pure Tcl (baseline) JPEG decoder.
# Copyright (c) 2017 dbohdan and contributors listed in AUTHORS
# License: MIT.
source ptjd.tcl

set numTests(Total)    0
set numTests(Passed)   0
set numTests(Failed)   0
set numTests(Skipped)  0

if {[info exists ::tcl_platform(engine)]} {
    set testConstraints(jim) [expr {$tcl_platform(engine) eq "Jim"}]
    set testConstraints(tcl) [expr {$tcl_platform(engine) eq "Tcl"}]
} else {
    set testConstraints(jim) [expr {![catch {
        proc foo {} {{bar 0}} {}; info statics foo; rename foo {}
    }]}]
    set testConstraints(tcl) [string match 8.*  [info patchlevel]]
}

set debugChan stdout ;# The channel to which we'll print errors.

# A basic tcltest-like test command compatible with both Tcl 8.5+ and Jim Tcl.
proc test {name descr args} {
    incr ::numTests(Total)
    array set testOpts $args
    set testState(failed) 0
    set testState(details) {}

    if {[info exists testOpts(-constraints)]} {
        foreach constr $testOpts(-constraints) {
            if {![info exists ::testConstraints($constr)]
                    || !$::testConstraints($constr)} {
                incr ::numTests(Skipped)
                return
            }
        }
    }

    # A dummy [for] to use [break] to go to the end of the block on error. This
    # idiom was described by Lars H on https://wiki.tcl-lang.org/901.
    for {} 1 break {
        if {[info exists testOpts(-setup)]
                && [catch $testOpts(-setup) \
                          testState(catchRes) \
                          testState(catchOpts)]} {
            set testState(failed) 1
            set testState(details) {during setup}
            break
        }

        catch $testOpts(-body) testState(catchRes) testState(catchOpts)
        # Store the result of the body of the test for later.
        set testState(actual)   $testState(catchRes)
        set testState(expected) $testOpts(-result)

        if {[dict get $testState(catchOpts) -code] != 0} {
            set testState(failed) 1
            set testState(details) {during run}
            break
        }

        if {[info exists testOpts(-cleanup)]
                && [catch $testOpts(-cleanup) \
                          testState(catchRes) \
                          testState(catchOpts)]} {
            set testState(failed) 1
            set testState(details) {during cleanup}
            break
        }

        if {$testState(actual) ne $testState(expected)} {
            set testState(failed) 1
            set testState(details) {with wrong result}
        }
    }

    if {$testState(failed)} {
        incr ::numTests(Failed)
        puts $::debugChan "==== $name $descr\
                           [concat FAILED $testState(details)]"
        puts $::debugChan "==== Contents of test case:\n$testOpts(-body)"
        puts $::debugChan "---- errorCode:\
                           [dict get $testState(catchOpts) -code]"
        if {[dict get $testState(catchOpts) -code] != 0} {
            # The test returned an error code.
            puts $::debugChan "---- Result:    $testState(catchRes)"
            # Prettify a Jim Tcl stack trace.
            if {$::testConstraints(jim)} {
                puts $::debugChan "---- errorInfo:"
                foreach {proc file line} [dict get $testState(catchOpts) \
                                                   -errorinfo] {
                    puts $::debugChan "in \[$proc\] on line $line of $file"
                }
            } else {
                puts $::debugChan "---- errorInfo:
                                   [dict get $testState(catchOpts) -errorinfo]"
            }
        } else {
            # The test returned a wrong result.
            if {$::tcl_platform(platform) eq "unix"} {
                set color(normal) "\033\[0m"
                set color(green)  "\033\[0;32m"
                set color(red)    "\033\[0;31m"
            } else {
                set color(normal) {}
                set color(green)  {}
                set color(red)    {}
            }
            # Find the first differing character.
            for {set i 0} {$i < [string length $testState(expected)]} {incr i} {
                if {[string index $testState(actual) $i] ne
                        [string index $testState(expected) $i]} {
                    break
                }
            }
            set highlighted    $color(green)
            append highlighted [string range $testState(actual) 0 $i-1]
            append highlighted $color(red)
            append highlighted [string range $testState(actual) $i end]
            append highlighted $color(normal)
            puts $::debugChan "---- Expected result: $testState(expected)"
            puts $::debugChan "---- Actual result:   $highlighted"
        }
        puts $::debugChan "==== $name $descr\
                           [concat FAILED $testState(details)]\n"
    } else {
        incr ::numTests(Passed)
    }
}

# Decoded binary data encoded as a list of hex values.
proc decode-hex data {
    set canDecodeHex [expr {![catch {binary decode hex FF}]}]
    set canPack [expr {![catch {pack _ 0xFF -intle 8}]}]
    if {$canDecodeHex} {
        # Tcl 8.6
        return [binary decode hex $data]
    } elseif {$canPack} {
        # Jim Tcl
        set result {}
        foreach x $data {
            pack v [expr 0x$x] -intle 8
            append result $v
        }
        return $result
    } else {
        # Tcl 8.5
        set result {}
        foreach x $data {
            append result [binary format c 0x$x]
        }
        return $result
    }
}

# Recursively remove whitespace from $list and its nested lists.
proc sws {list {level 1}} {
    if {$level <= 0} { return $list }
    set result {}
    foreach item $list {
        lappend result [sws $item [expr {$level - 1}]]
    }
    return $result
}

# Pretty-print a dictionary mapping Huffman codes to values.
proc format-codes codes {
    set result {}
    set pairs {}
    foreach {code value} $codes {
        lappend pairs [list $code $value]
    }
    foreach pair [lsort -index 0 $pairs] {
        lassign $pair code value
        lappend result {*}[format {%s -> %x} $code $value]
    }
    return $result
}

# Return $d sorted by the key.
proc dict-sort d {
    set result {}
    set keys [lsort [dict keys $d]]
    foreach key $keys {
        lappend result $key [dict get $d $key]
    }
    return $result
}

# A hack to get around the fact that Jim Tcl's dictionary operations do not
# preserve the order.
proc sort-frame frame {
    set x [lindex $frame 1]
    set componentsSorted {}
    foreach component [dict get $x components] {
        lappend componentsSorted [dict-sort $component]
    }
    dict set x components $componentsSorted
    lset frame 1 [dict-sort $x]
    return $frame
}

proc read-test-file filename {
    set h [open [file join test-data $filename] rb]
    set result [read $h]
    close $h
    return $result
}

# Flatten nested lists.
proc flatten {list {n 1}} {
    if {$n <= 0} { return $list }
    set result {}
    foreach x $list {
        lappend result {*}[flatten $x [expr {$n - 1}]]
    }
    return $result
}

test decode-hex-1.1 {Decode hex-encoded binary data} -body {
    binary scan [decode-hex {
        FF DA 00 0C 03 01 00 02 11 03 11 00 3F 00
    }] H28 scanned
    return $scanned
} -result ffda000c03010002110311003f00

test int-to-binary-digits-1.1 {Convert an integer to its binary\
                               representation} -body {
    list [::ptjd::int-to-binary-digits   34   ] \
         [::ptjd::int-to-binary-digits   34  1] \
         [::ptjd::int-to-binary-digits   34  6] \
         [::ptjd::int-to-binary-digits   34 10] \
         [::ptjd::int-to-binary-digits 4096 10]
} -result {100010 100010 100010 0000100010 1000000000000}

test block-count-1.1 {Map pixel count and scaling factor to block count} -body {
    list [::ptjd::block-count   5 1 1] \
         [::ptjd::block-count   5 1 2] \
         [::ptjd::block-count   5 2 2] \
         [::ptjd::block-count   8 1 1] \
         [::ptjd::block-count   8 1 2] \
         [::ptjd::block-count   8 2 2] \
         [::ptjd::block-count  16 1 1] \
         [::ptjd::block-count  16 1 2] \
         [::ptjd::block-count  16 2 2] \
         [::ptjd::block-count 418 1 1] \
         [::ptjd::block-count 418 1 2] \
         [::ptjd::block-count 418 2 2] \
         [::ptjd::block-count 840 1 1] \
         [::ptjd::block-count 840 1 2] \
         [::ptjd::block-count 840 2 2]
} -result [sws {1 2 1  1 2 1   2 2 1   53 54 27   105 106 53}]

test li-lo-1.1 {::ptjd::hi-lo} -setup {
    set result {}
} -body {
    lappend result [::ptjd::hi-lo 0x0F]
    lappend result [::ptjd::hi-lo 0xF0]
    lappend result [::ptjd::hi-lo 0x57]
} -cleanup {
    unset result
} -result {{0 15} {15 0} {5 7}}

test read-tables-1.1 {QT} -body {
    set x [::ptjd::read-tables \xFF\xD9 [decode-hex {
        FF DB 00 43 00 08 06 06 07 08 07 08 08 08 08 09 09 08 0A 0C 14 0D 0C
        0B 0B 0C 19 12 13 0F 14 1D 1A 1F 1E 1D 1A 1C 1C 20 24 2E 27 20 22 2C
        23 1C 1C 28 37 29 2C 30 31 34 34 34 1F 27 39 3D 38 32 3C 2E 33 34 32
        FF DB 00 43 01 09 08 08 10 10 10 10 10 10 10 20 20 20 20 20 40 40 40
        40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40
        40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40
        FF D9
    }] 0 {} {} {} {}]
    lset x 1 0 [::ptjd::unzigzag [lindex $x 1 0]]
    lset x 1 1 [::ptjd::unzigzag [lindex $x 1 1]]
    return $x
} -cleanup {
    unset x
} -result [sws {
    138
    {
        {
             8  6  7  8 12 20 26 31
             6  8  8 10 13 29 30 28
             7  8  8 12 20 29 35 28
             8  9 11 15 26 44 40 31
             9 11 19 28 34 55 52 39
            12 18 28 32 41 52 57 46
            25 32 39 44 52 61 60 51
            36 46 48 49 56 50 52 50
        }
        {
             9  8 16 16 32 64 64 64
             8 16 16 32 64 64 64 64
            16 16 32 64 64 64 64 64
            16 32 64 64 64 64 64 64
            32 64 64 64 64 64 64 64
            64 64 64 64 64 64 64 64
            64 64 64 64 64 64 64 64
            64 64 64 64 64 64 64 64
        } {} {}
    } {{} {} {} {}} {{} {} {} {}} {}} 3]


test tables-1.2 {QT} -body {
    set x [::ptjd::read-tables \xFF\xD9 [decode-hex {
        FF DB 00 43 00 02 01 01 01 01 01 02 01 01 01 02 02 02 02 02 04 03 02 02
        02 02 05 04 04 03 04 06 05 06 06 06 05 06 06 06 07 09 08 06 07 09 07 06
        06 08 0B 08 09 0A 0A 0A 0A 0A 06 08 0B 0C 0B 0A 0C 09 0A 0A 0A FF DB 00
        43 01 02 02 02 02 02 02 05 03 03 05 0A 07 06 07 0A 0A 0A 0A 0A 0A 0A 0A
        0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A
        0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A
        FF D9
    }] 0 {} {} {} {}]
    lset x 1 0 [::ptjd::unzigzag [lindex $x 1 0]]
    lset x 1 1 [::ptjd::unzigzag [lindex $x 1 1]]
    return $x
} -cleanup {
    unset x
} -result [sws {
    138
    {
        {
             2   1   1   2   2   4   5   6 
             1   1   1   2   3   6   6   6 
             1   1   2   2   4   6   7   6 
             1   2   2   3   5   9   8   6 
             2   2   4   6   7  11  10   8 
             2   4   6   6   8  10  11   9 
             5   6   8   9  10  12  12  10 
             7   9  10  10  11  10  10  10
        }
        {
             2   2   2   5  10  10  10  10 
             2   2   3   7  10  10  10  10 
             2   3   6  10  10  10  10  10 
             5   7  10  10  10  10  10  10 
            10  10  10  10  10  10  10  10 
            10  10  10  10  10  10  10  10 
            10  10  10  10  10  10  10  10 
            10  10  10  10  10  10  10  10 
        } {} {}
    }
    {{} {} {} {}} {{} {} {} {}} {}} 3]

test huffman-1.1 {Huffman codes} -body {
    format-codes [::ptjd::generate-huffman-codes {
        0 {} {4 5 6} 7 3 8 1 2 {} {} {} {} {} {} {} {}
    }]
} -result [sws {
    0 -> 0
    100 -> 4
    101 -> 5
    110 -> 6
    1110 -> 7
    11110 -> 3
    111110 -> 8
    1111110 -> 1
    11111110 -> 2
}]

test huffman-1.2 {Huffman codes} -body {
    format-codes [::ptjd::generate-huffman-codes {
        {} 1 {2 3 4} {0 5 17} {6 18 33} 49 {19 65} {7 20 21 34 81 97 113}
        {23 35 50 54 129 145 179} {22 66 82 85 86 117 147 177 209 210 211}
        {51 84 99 116 131 148 149 150 161 162 164 225}
        {24 36 52 53 98 101 114 130 178 180 226 227 240}
        {55 67 83 102 146 163 193 212 228} {8 37 69 100 194 195}
        {38 68 70 115 132} {181 241 198 39 133}
    }]
} -result [sws {
    00 -> 1
    010 -> 2 
    011 -> 3
    100 -> 4
    1010 -> 0
    1011 -> 5
    1100 -> 11
    11010 -> 6
    11011 -> 12
    11100 -> 21
    111010 -> 31
    1110110 -> 13
    1110111 -> 41
    11110000 -> 7
    11110001 -> 14
    11110010 -> 15
    11110011 -> 22
    11110100 -> 51
    11110101 -> 61
    11110110 -> 71
    111101110 -> 17
    111101111 -> 23
    111110000 -> 32
    111110001 -> 36
    111110010 -> 81
    111110011 -> 91
    111110100 -> b3
    1111101010 -> 16
    1111101011 -> 42
    1111101100 -> 52
    1111101101 -> 55
    1111101110 -> 56
    1111101111 -> 75
    1111110000 -> 93
    1111110001 -> b1
    1111110010 -> d1
    1111110011 -> d2
    1111110100 -> d3
    11111101010 -> 33
    11111101011 -> 54
    11111101100 -> 63
    11111101101 -> 74
    11111101110 -> 83
    11111101111 -> 94
    11111110000 -> 95
    11111110001 -> 96
    11111110010 -> a1
    11111110011 -> a2
    11111110100 -> a4
    11111110101 -> e1
    111111101100 -> 18
    111111101101 -> 24
    111111101110 -> 34
    111111101111 -> 35
    111111110000 -> 62
    111111110001 -> 65
    111111110010 -> 72
    111111110011 -> 82
    111111110100 -> b2
    111111110101 -> b4
    111111110110 -> e2
    111111110111 -> e3
    111111111000 -> f0
    1111111110010 -> 37
    1111111110011 -> 43
    1111111110100 -> 53 
    1111111110101 -> 66
    1111111110110 -> 92
    1111111110111 -> a3
    1111111111000 -> c1
    1111111111001 -> d4
    1111111111010 -> e4
    11111111110110 -> 8
    11111111110111 -> 25
    11111111111000 -> 45
    11111111111001 -> 64
    11111111111010 -> c2
    11111111111011 -> c3
    111111111111000 -> 26
    111111111111001 -> 44
    111111111111010 -> 46
    111111111111011 -> 73
    111111111111100 -> 84
    1111111111111010 -> b5
    1111111111111011 -> f1
    1111111111111100 -> c6
    1111111111111101 -> 27
    1111111111111110 -> 85
}]

test inverse-dct-1.1 {Inverse DCT} -body {
    ::ptjd::inverse-dct {
        -416  -33  -60   32   48  -40    0    0
           0  -24  -56   19   26    0    0    0
         -42   13   80  -24  -40    0    0    0
         -42   17   44  -29    0    0    0    0
          18    0    0    0    0    0    0    0
           0    0    0    0    0    0    0    0
           0    0    0    0    0    0    0    0
           0    0    0    0    0    0    0    0
    }
} -result [sws {
    -66  -63  -71  -68  -56  -65  -68  -46
    -71  -73  -72  -46  -20  -41  -66  -57
    -70  -78  -68  -17   20  -14  -61  -63
    -63  -73  -62   -8   27  -14  -60  -58
    -58  -65  -61  -27   -6  -40  -68  -50
    -57  -57  -64  -58  -48  -66  -72  -47
    -53  -46  -61  -74  -65  -63  -62  -45
    -47  -34  -53  -74  -60  -47  -47  -41
}]

test combine-and-crop-1.1 {Combine blocks into a plane} -body {
    ::ptjd::crop 3 23 18 [::ptjd::combine-blocks 3 3 1 1 [list \
        [lrepeat 64 0] [lrepeat 64 1] [lrepeat 64 2] \
        [lrepeat 64 3] [lrepeat 64 4] [lrepeat 64 5] \
        [lrepeat 64 6] [lrepeat 64 7] [lrepeat 64 8]]]
} -result [sws {
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2
    3 3 3 3 3 3 3 3 4 4 4 4 4 4 4 4 5 5 5 5 5 5 5
    3 3 3 3 3 3 3 3 4 4 4 4 4 4 4 4 5 5 5 5 5 5 5
    3 3 3 3 3 3 3 3 4 4 4 4 4 4 4 4 5 5 5 5 5 5 5
    3 3 3 3 3 3 3 3 4 4 4 4 4 4 4 4 5 5 5 5 5 5 5
    3 3 3 3 3 3 3 3 4 4 4 4 4 4 4 4 5 5 5 5 5 5 5
    3 3 3 3 3 3 3 3 4 4 4 4 4 4 4 4 5 5 5 5 5 5 5
    3 3 3 3 3 3 3 3 4 4 4 4 4 4 4 4 5 5 5 5 5 5 5
    3 3 3 3 3 3 3 3 4 4 4 4 4 4 4 4 5 5 5 5 5 5 5
    6 6 6 6 6 6 6 6 7 7 7 7 7 7 7 7 8 8 8 8 8 8 8
    6 6 6 6 6 6 6 6 7 7 7 7 7 7 7 7 8 8 8 8 8 8 8
}]

test scale-1.1 {Scale a color plane} -body {
    ::ptjd::scale-double 2 1 1 2 [::ptjd::combine-blocks 2 1 1 1 [list \
        [lrepeat 64 0] [lrepeat 64 1]]]
} -result [sws {
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
}]

test scale-1.2 {Scale a color plane} -body {
    ::ptjd::scale-double 1 2 2 1 [::ptjd::combine-blocks 1 2 1 1 [list \
        [lrepeat 64 0] [lrepeat 64 1]]]
} -result [sws {
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
}]

test scale-2.1 {Scale a color plane} -body {
    ::ptjd::scale-linear 2 1 1 2 [::ptjd::combine-blocks 2 1 1 1 [list \
        [lrepeat 64 0] [lrepeat 64 1]]]
} -result [sws {
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
    0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1
}]

test scale-2.2 {Scale a color plane} -body {
    ::ptjd::scale-linear 1 2 2 1 [::ptjd::combine-blocks 1 2 1 1 [list \
        [lrepeat 64 0] [lrepeat 64 1]]]
} -result [sws {
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
}]

test decode-1.1 {Complete file decode} -body {
    ::ptjd::decode [read-test-file ycbcr.jpg]
} -result [list \
    16 16 3 \
    [flatten [list [lrepeat 8 [lrepeat 24        0 ] [lrepeat 8 {254 0 0}]] \
                   [lrepeat 8 [lrepeat  8 {0 255 1}] [lrepeat 8 {0 0 254}]]] \
             4]]

test decode-1.2 {Complete file decode} -body {
    ::ptjd::decode [read-test-file grayscale.jpg]
} -result [::ptjd::ppm-to-image [read-test-file grayscale.pgm]]

test decode-1.3 {Complete file decode} -body {
    ::ptjd::decode [read-test-file ycbcr-h.jpg] ::ptjd::scale-double
} -result [::ptjd::ppm-to-image [read-test-file ycbcr-h.ppm]]

test decode-1.4 {Complete file decode} -body {
    ::ptjd::decode [read-test-file ycbcr-v.jpg] ::ptjd::scale-double
} -result [::ptjd::ppm-to-image [read-test-file ycbcr-v.ppm]]

test decode-1.5 {Complete file decode} -body {
    ::ptjd::decode [read-test-file ycbcr-q.jpg] ::ptjd::scale-double
} -result } -result [::ptjd::ppm-to-image [read-test-file ycbcr-q.ppm]]

test decode-2.1 {Decode an image with nontrivial AC coefficients} -body {
    ::ptjd::decode [read-test-file ycbcr-ac.jpg]
} -result [::ptjd::ppm-to-image [read-test-file ycbcr-ac.ppm]]

test decode-3.1 {Decode a file with restart markers} -body {
    ::ptjd::decode [read-test-file restart.jpg]
} -result [::ptjd::ppm-to-image [read-test-file restart.ppm]]

test decode-4.1 {Attempt to decode an empty file} -body {
    catch {::ptjd::decode {}} err
    return $err
} -result {failed to scan "a2" at 0x0}

test decode-5.1 {Attempt to decode a truncated file} -body {
    catch {::ptjd::decode [string range [read-test-file restart.jpg] 0 100]} err
    return $err
} -result {failed to scan "a2 Su" at 0x9e}

test decode-5.2 {Attempt to decode a truncated file} -body {
    catch {::ptjd::decode [string range [read-test-file restart.jpg] 0 300]} err
    return $err
} -result {failed to scan "cu125" at 0x10c}

test decode-5.3 {Attempt to decode a truncated file} -body {
    catch {::ptjd::decode [string range [read-test-file restart.jpg] 0 700]} err
    return [string range $err 0 end-2]
} -result {failed to scan "B8" at 0x2}

test decode-6.1 {Attempt to decode a file with a missing beginning} -body {
    catch {::ptjd::decode [string range [read-test-file restart.jpg] 2 end]} err
    return $err
} -result {expected "\xFF\xD8", but got "\xFF\xE0"}

test decode-7.1 {Attempt to decode a file with a missing middle} -body {
    set x [read-test-file restart.jpg]
    catch {::ptjd::decode [string range $x 0 100][string range $x 200 end]} err
    return $err
} -result {unsupported section "\xB1\xC1" at 0x9e}

test decode-7.2 {Attempt to decode a file with a missing middle} -body {
    set x [read-test-file restart.jpg]
    catch {::ptjd::decode [string range $x 0 200][string range $x 205 end]} err
    return $err
} -result {unsupported section "\x10\x0" at 0xd2}

test decode-8.1 {Attempt to decode a corrupted file} -body {
    set x [string map {WkY WAA} [read-test-file restart.jpg]]
    catch {::ptjd::decode $x} err
    return $err
} -result {expected "64", but got "65"}

test read-frame-header-1.1 {Frame header} -body {
    sort-frame [::ptjd::read-frame-header [decode-hex {
        FF C0 00 11 08 01 64 02 0D 03 01 11 00 02 11 01 03 11 01
    }] 0]
} -result [sws {
    19
    {
        components {{c 1 h 1 tq 0 v 1} {c 2 h 1 tq 1 v 1} {c 3 h 1 tq 1 v 1}}
        nf 3
        p 8
        x 525
        y 356
    }} 2]

test read-frame-header-1.2 {Frame header} -body {
    sort-frame [::ptjd::read-frame-header [decode-hex {
        FF C0 00 11 08 04 C9 03 51 03 01 22 00 02 11 01 03 11 01 FF C4 00 00
    }] 0]
} -result [sws {
    19
    {
        components {{c 1 h 2 tq 0 v 2} {c 2 h 1 tq 1 v 1} {c 3 h 1 tq 1 v 1}}
        nf 3
        p 8
        x 849
        y 1225
    }} 2]

test read-scan-header-1.3 {Scan header} -body {
    sort-frame [::ptjd::read-scan-header [decode-hex {
        FF DA 00 0C 03 01 00 02 11 03 11 00 3F 00
    }] 0]
} -result [sws {
    14
    {
        ah 0
        al 0
        components {{cs 1 ta 0 td 0} {cs 2 ta 1 td 1} {cs 3 ta 1 td 1}}
        ns 3
        se 63
        ss 0
    }} 2]

test get-bits-1.1 {Bit stream} -body {
    set bits {}
    set ptr 0
    for {set i 0} {$i < 24} {incr i} {
        lassign [::ptjd::get-bits \x11\xF0\xA5 $ptr $bits 1] ptr bits bit
        lappend result $bit
    }
    return $result
} -result [sws {0 0 0 1 0 0 0 1   1 1 1 1 0 0 0 0   1 0 1 0 0 1 0 1}]

test get-bits-2.1 {Bit stream with a restart marker} -body {
    set bits {}
    set ptr 0
    for {set i 0} {$i < 24} {incr i} {
        lassign [::ptjd::get-bits \x11\xFF\xD0\xF0\xFF\xD1\xA5 $ptr $bits 1] \
                ptr bits bit
        lappend result $bit
    }
    return $result
} -result [sws {0 0 0 1 0 0 0 1   1 1 1 1 0 0 0 0   1 0 1 0 0 1 0 1}]

test get-bits-2.2 {Bit stream with a restart marker} -body {
    set bits {}
    set ptr 0
    for {set i 0} {$i < 16} {incr i} {
        lassign [::ptjd::get-bits \xFF\xD0\xFF\x00\xFF\x00 $ptr $bits 1] \
                ptr bits bit
        lappend result $bit
    }
    return $result
} -result [sws {1 1 1 1 1 1 1 1   1 1 1 1 1 1 1 1}]

puts $::debugChan \
     [format "%s:   Total %2u   Passed %2u   Failed %2u   Skipped %2u" \
             $argv0 $::numTests(Total) $::numTests(Passed) \
             $::numTests(Failed) $::numTests(Skipped)]

# Exit with a nonzero status if there are failed tests.
if {$numTests(Failed) > 0} {
    exit 1
}
