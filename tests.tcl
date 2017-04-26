# PTJD, a pure Tcl (baseline) JPEG decoder.
# Copyright (c) 2017 dbohdan and contributors listed in AUTHORS
# License: MIT.
source ptjd.tcl

set numTests(Total)    0
set numTests(Passed)   0
set numTests(Failed)   0
set numTests(Skipped)  0

set testConstraints(jim) [string match *jim* [info nameofexecutable]]
set testConstraints(tcl) [string match 8.*   [info patchlevel]]

# A basic tcltest-like test command compatible with both Tcl 8.5+ and Jim Tcl.
# Not the prettiest implementation.
proc test {name descr args} {
    incr ::numTests(Total)
    set failed 0
    set details {}

    if {[dict exists $args -constraints]} {
        foreach constr [dict get $args -constraints] {
            if {![info exists ::testConstraints($constr)]
                || !$::testConstraints($constr)} {
                incr ::numTests(Skipped)
                return
            }
        }
    }

    if {[dict exists $args -setup]
        && [catch [dict get $args -setup] catchRes opts]} {
        set failed 1
        set details {during setup}
    } else {
        catch [dict get $args -body] catchRes opts
        # Store the result of the body of the test for later.
        set actual $catchRes

        if {[dict get $opts -code] == 0} {
            if {[dict exists $args -cleanup]
                && [catch [dict get $args -cleanup] catchRes opts]} {
                set failed 1
                set details {during cleanup}
            }
            if {$actual ne [dict get $args -result]} {
                set failed 1
                set details {with wrong result}
            }
        } else {
            set failed 1
            set details {during run}
        }
    }
    if {$failed} {
        incr ::numTests(Failed)
        puts stdout "==== $name $descr [concat FAILED $details]"
        puts stdout "==== Contents of test case:\n[dict get $args -body]"
        set code [dict get $opts -code]
        puts stdout "---- errorCode: $code"
        if {$code != 0} {
            puts stdout "---- Result:    $catchRes"
            if {$::testConstraints(jim)} {
                puts stdout "---- errorInfo:"
                foreach {proc file line} [dict get $opts -errorinfo] {
                    puts stdout "in \[$proc\] on line $line of $file"
                }
            } else {
                puts stdout "---- errorInfo: [dict get $opts -errorinfo]"
            }
        } else {
            puts stdout "---- Expected result: [dict get $args -result]"
            puts stdout "---- Actual result:   $actual"
        }
        puts stdout "==== $name $descr [concat FAILED $details]\n"
    } else {
        incr ::numTests(Passed)
    }
}

# Decoded binary data encoded as a list of hex values.
proc decode-hex data {
    if {$::testConstraints(jim)} {
        set result {}
        foreach x $data {
            pack v [expr 0x$x] -intle 8
            append result $v
        }
        return $result
    } else {
        return [binary decode hex $data]
    }
}

# Recursively remove whitespace from $list and its nested lists.
proc sws {list {level 0}} {
    set result {}
    foreach item $list {
        if {$level == 0} {
            lappend result $item
        } else {
            lappend result [sws $item [expr {$level - 1}]]
        }
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

test decode-hex {Decoding hex-encoded binary data} -body {
    binary scan [decode-hex {
        FF DA 00 0C 03 01 00 02 11 03 11 00 3F 00
    }] H28 scanned
    return $scanned
} -result ffda000c03010002110311003f00

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
    }] 0 {} {} {}]
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
    } {{} {} {} {}} {{} {} {} {}}} 2]


test tables-1.2 {QT} -body {
    set x [::ptjd::read-tables \xFF\xD9 [decode-hex {
        FF DB 00 43 00 02 01 01 01 01 01 02 01 01 01 02 02 02 02 02 04 03 02 02
        02 02 05 04 04 03 04 06 05 06 06 06 05 06 06 06 07 09 08 06 07 09 07 06
        06 08 0B 08 09 0A 0A 0A 0A 0A 06 08 0B 0C 0B 0A 0C 09 0A 0A 0A FF DB 00
        43 01 02 02 02 02 02 02 05 03 03 05 0A 07 06 07 0A 0A 0A 0A 0A 0A 0A 0A
        0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A
        0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A
        FF D9
    }] 0 {} {} {}]
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
    {{} {} {} {}} {{} {} {} {}}} 2]

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

test combine-blocks-1.1 {Combining blocks into a plane} -body {
    ::ptjd::combine-blocks 23 18 [list \
        [lrepeat 64 0] [lrepeat 64 1] [lrepeat 64 2] \
        [lrepeat 64 3] [lrepeat 64 4] [lrepeat 64 5] \
        [lrepeat 64 6] [lrepeat 64 7] [lrepeat 64 8]]
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

set fourColorsRaw {
    FF D8 FF E0 00 10 4A 46 49 46 00 01 01 01 00 48 00 48 00 00 FF DB 00 43
    00 02 01 01 01 01 01 02 01 01 01 02 02 02 02 02 04 03 02 02 02 02 05 04
    04 03 04 06 05 06 06 06 05 06 06 06 07 09 08 06 07 09 07 06 06 08 0B 08
    09 0A 0A 0A 0A 0A 06 08 0B 0C 0B 0A 0C 09 0A 0A 0A FF DB 00 43 01 02 02
    02 02 02 02 05 03 03 05 0A 07 06 07 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A
    0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A
    0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A 0A FF C0 00 11 08 00 10 00 10 03
    01 11 00 02 11 01 03 11 01 FF C4 00 16 00 01 01 01 00 00 00 00 00 00 00
    00 00 00 00 00 00 08 07 09 FF C4 00 1F 10 00 02 02 03 01 00 03 01 00 00
    00 00 00 00 00 00 03 04 02 05 01 06 07 08 11 14 15 13 FF C4 00 17 01 00
    03 01 00 00 00 00 00 00 00 00 00 00 00 00 00 05 06 09 08 FF C4 00 29 11
    01 00 01 02 04 05 02 07 00 00 00 00 00 00 00 00 01 02 03 11 04 05 06 21
    00 07 12 31 71 22 61 13 15 32 41 51 C1 F0 FF DA 00 0C 03 01 00 02 11 03
    11 00 3F 00 2E 79 4F CE DC F3 CD F5 4C 68 5C 73 CE 55 DD 0B A0 CB 65 16
    A9 5D D8 6A 37 15 83 71 B3 DD 36 C2 93 19 34 96 AC 04 4A AA 44 AB A4 B6
    09 2B EC 06 C2 CA 58 B6 AD CC 31 51 3B 0C FE 71 C9 69 BC CA A5 06 74 63
    74 8B 24 B9 E9 3D DF EE CF E1 E0 DE 0B 2B AF 3A B0 6E 31 EE EF 70 3E FE
    7C 1E 3B F1 45 F7 2E E3 D9 3B 17 56 0F 6E EE FD 7E 8F 67 BD DA 15 29 20
    96 BD 17 32 A5 3A E1 2C C5 15 56 21 41 15 8E BC 0B 06 05 12 28 66 07 32
    00 D2 91 67 29 E4 93 52 8F 26 F5 86 A0 CF E9 D5 C7 53 1A 6D C6 CF D1 B0
    82 21 66 C8 DB DE EF 7B B4 B3 93 1A AB 47 69 DD 29 53 2D CB A8 B4 4A 7D
    2B 29 4A 0B 56 52 37 92 12 64 36 06 D3 8C 50 62 00 16 18 2D 73 DA DF 46
    76 9A 2D 2E 8B CF 74 94 34 94 84 4E C9 8D BD 62 A1 F7 F2 A2 84 83 4F CD
    D7 8A 31 13 EC 48 6B E4 21 94 FE 56 8E 4C 18 67 20 86 49 9C 21 F2 97 98
    10 C6 62 F2 E8 60 F3 14 20 4A F8 56 32 97 4A F6 65 3E ED D6 FB 78 37 E2
    0D 72 B3 98 98 7C FB 19 97 C3 07 8F 61 46 91 26 58 5B 32 63 EF 2A 8F 7B
    BE 03 63 8C FB E7 5E C2 F3 A5 47 A1 AA EB 34 2E 23 CB 43 B2 6D 3D 0E 4B
    ED 9B 6E E1 59 03 E9 22 5C 8F A9 F5 65 5C 83 C0 1F E3 56 82 0B 90 7F D4
    A3 93 51 55 F6 B3 99 06 70 0C 41 59 E5 CA EC D2 B6 87 F9 86 61 88 AD 2A
    14 E9 46 74 E9 53 02 B8 94 E5 D4 33 8B 2F 8B 39 32 10 2D 1E B8 C4 F5 0B
    7D 81 81 D7 19 6C F1 7D 11 AD 20 A9 6B EE 96 B1 63 7D BF 5C 7F FF D9
}

set fourColorsDecoded [sws {
    16 16 3
    {

        1 3 0 1 0 0 12 0 4 12 0 4 1 1 0 4 0 0 11 0 6 251 251 249 255 251 250 255
        240 241 247 215 218 218 18 21 249 4 0 254 1 0 248 5 1 245 3 1 0 1 0 0 8
        0 0 5 2 2 0 8 2 1 0 254 254 254 255 248 249 30 4 5 254 243 247 255 228
        243 186 28 19 229 9 21 243 6 0 249 6 10 251 0 14 249 2 23 5 2 11 1 4 0 5
        4 2 251 255 245 254 255 253 251 251 243 8 0 2 38 4 3 255 223 224 189 25
        34 219 15 26 245 4 10 251 0 0 242 1 17 243 0 44 232 1 35 2 0 18 9 0 6
        249 254 255 255 254 255 9 0 5 0 0 4 255 250 255 255 237 231 164 39 47
        209 14 28 228 11 19 237 1 13 247 8 11 251 0 31 243 4 71 232 0 74 0 4 0
        255 254 255 13 0 30 12 0 23 5 0 11 246 252 250 7 3 0 48 4 0 162 34 35
        189 36 20 197 31 31 206 23 17 233 0 4 250 2 36 224 0 77 229 0 119 255
        249 244 19 0 26 111 63 121 25 0 41 253 245 255 21 6 27 21 0 17 58 0 15
        159 38 81 252 202 239 254 207 249 255 206 241 224 12 50 226 4 65 225 8
        125 205 0 130 255 225 255 118 61 138 29 0 53 33 0 62 255 222 255 104 49
        142 125 52 133 254 221 255 255 209 251 169 38 142 174 21 145 170 16 130
        212 7 128 208 0 131 205 8 158 191 0 172 18 11 53 83 72 114 102 62 125
        255 228 254 41 4 81 116 53 160 111 52 162 254 217 251 124 40 162 137 29
        166 252 208 244 148 26 186 176 16 166 173 7 165 179 14 179 175 14 180 67
        205 83 102 186 108 85 67 125 113 53 143 85 72 125 78 78 116 87 70 140
        166 123 231 68 0 124 126 35 190 56 0 181 69 0 183 142 34 198 96 0 128 98
        3 133 132 36 170 50 221 47 72 205 80 234 253 249 247 255 255 111 172 130
        109 174 142 68 75 129 167 126 222 255 217 255 116 49 190 38 4 176 43 0
        172 120 39 206 255 207 255 251 212 255 251 227 255 94 189 89 191 253 190
        188 255 189 60 205 64 38 225 48 62 212 87 64 92 114 167 126 228 254 216
        255 103 46 177 38 9 119 255 232 255 108 45 198 253 210 255 70 0 155 255
        209 251 192 255 183 180 250 180 69 200 86 54 215 77 40 224 52 66 202 78
        59 85 98 252 227 255 78 5 148 116 50 202 253 228 255 251 226 245 99 39
        222 66 0 193 116 33 229 121 41 234 28 228 31 65 213 77 41 99 75 67 89
        103 98 182 133 108 178 144 73 81 102 255 240 255 41 8 139 103 48 227 104
        40 238 103 39 247 95 48 252 51 2 216 106 34 230 117 33 219 0 252 0 41
        224 58 114 177 156 54 84 95 44 106 65 41 102 69 238 252 253 133 146 191
        242 239 255 36 0 191 43 0 220 41 0 231 31 0 237 30 0 222 53 2 205 253
        211 255 2 255 5 18 243 27 37 227 41 51 219 72 64 217 65 74 195 82 215
        255 232 235 255 254 7 28 155 12 10 215 9 1 222 9 6 247 1 1 247 8 2 226
        27 0 200 255 228 251 5 255 14 0 255 17 1 251 4 10 255 9 29 231 35 164
        252 165 205 255 217 116 153 180 10 34 166 4 9 223 4 7 246 0 1 253 2 5
        242 1 1 239 7 9 208 13 1 187
    }
} 2]

test decode-1.1 {Complete file decode} -body {
    ::ptjd::decode [decode-hex $::fourColorsRaw]
} -result $fourColorsDecoded

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
    }} 1]

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
    }} 1]

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
    }} 1]

test get-bit-1.1 {Bit stream} -setup {
    set bits {}
    set ptr 0
    set result {}
} -body {
    for {set i 0} {$i < 24} {incr i} {
        lassign [::ptjd::get-bit \x11\xF0\xA5 $ptr $bits] ptr bits bit
        lappend result $bit
    }
    return $result
} -cleanup {
    unset bit bits i ptr result
} -result {0 0 0 1 0 0 0 1 1 1 1 1 0 0 0 0 1 0 1 0 0 1 0 1}

puts [format "%s:   Total %2u   Passed %2u   Failed %2u   Skipped %2u" \
             $argv0 $::numTests(Total) $::numTests(Passed) \
             $::numTests(Failed) $::numTests(Skipped)]

# Exit with a nonzero status if there are failed tests.
if {$numTests(Failed) > 0} {
    exit 1
}
