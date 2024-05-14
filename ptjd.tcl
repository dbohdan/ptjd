# A pure Tcl (baseline) JPEG decoder.
# Copyright (c) 2017, 2020 D. Bohdan and contributors listed in AUTHORS.
# License: MIT.

namespace eval ::ptjd {
    variable version 0.1.2
    variable inverseDctMatrix {}

    # Precompute the inverse DCT matrix.
    set pi 3.1415926535897931
    for {set x 0} {$x < 8} {incr x} {
        for {set u 0} {$u < 8} {incr u} {
            set alpha [expr {$u == 0 ? 1/sqrt(2) : 1}]
            lappend inverseDctMatrix [expr {
                $alpha * cos(((2*$x + 1) * $u * $pi)/16.0)
            }]
        }
    }
    unset alpha pi u x
}

# Use [string bytelength] on binary data in Jim Tcl.
if {[catch {
    proc ::ptjd::foo {} {}
    info statics ::ptjd::foo
    rename ::ptjd::foo {}
}]} {
    # Tcl 8.5-9.0 doesn't have [info statics].
    proc ::ptjd::bytelength s {
        return [string length $s]
    }
} else {
    # We are in Jim Tcl.
    proc ::ptjd::bytelength s {
        return [string bytelength $s]
    }
}

# Escape the unprintable binary data in $s for printing in error messages.
proc ::ptjd::escape-unprintable s {
    set result {}
    foreach c [split $s {}] {
        set code [scan $c %c]
        if {(0x20 <= $code) && ($code <= 0x7F)} {
            append result $c
        } else {
            append result [format \\x%X $code]
        }
    }
    return $result
}

# Throw an error if $actual does not equal $expected.
proc ::ptjd::assert-equal {actual expected} {
    if {$actual ne $expected} {
        error "expected \"[escape-unprintable $expected]\",\
               but got \"[escape-unprintable $actual]\""
    }
}

# Convert an integer to a string of binary digits. A [format %0${width}b $x]
# substitute for Tcl 8.5.
proc ::ptjd::int-to-binary-digits {x {width 0}} {
    # The credit for the trick used here goes to RS
    # (https://wiki.tcl-lang.org/15598).
    set bin [string trimleft [string map {
        0 0000 1 0001 2 0010 3 0011 4 0100 5 0101 6 0110 7 0111
        8 1000 9 1001 a 1010 b 1011 c 1100 d 1101 e 1110 f 1111
    } [format %x $x]] 0]
    if {($width) > 0 && ([bytelength $bin] < $width)} {
        set bin [string repeat 0 [expr {$width - [bytelength $bin]}]]$bin
    }
    return $bin
}

# Take a table of values and return a dictionary mapping a Huffman code to each
# of these values. The Huffman codes are represented as binary digits.
proc ::ptjd::generate-huffman-codes table {
    set prefixes {}
    set codes {}
    for {set i 1} {$i <= 16} {incr i} {
        set values [lindex $table $i-1]
        for {set j 0} {($values ne {}) && ($j < (1 << $i))} {incr j} {
            set used 0
            foreach {prLen prefix} $prefixes {
                if {$j >> ($i - $prLen) == $prefix} {
                    set used 1
                    break
                }
            }
            if {$used} { continue }
            set values [lassign $values value]
            dict set codes [int-to-binary-digits $j $i] $value
            lappend prefixes $i $j
        }
        if {$values ne {}} {
            error "couldn't assign codes to values [list $values] (length $i)"
        }
    }
    return $codes
}

# [binary scan] the data in the variable $data (in the caller's scope) starting
# at the offset $ptr (in the same scope) and store the results in the variables
# (ditto) listed in $args.
proc ::ptjd::scan-at-ptr {format args} {
    upvar 1 data data ptr ptr
    foreach varName $args {
        upvar 1 $varName $varName
    }
    if {![binary scan $data [concat @$ptr $format] {*}$args]} {
        error "failed to scan \"$format\" at 0x[format %x $ptr]"
    }
}

# Return a list containing the high and the low nibble (4-bit value) of a byte.
proc ::ptjd::hi-lo byte {
    set byte [expr {$byte & 0xFF}]
    return [list [expr {$byte >> 4}] [expr {$byte & 0x0F}]]
}

# Read quantization tables, Huffman tables, restart interval definitions, APP
# sections and comments from $data starting at $ptr until $until is encountered.
# Return a list containing the new values for $ptr, $qts, $huffdc, $huffac and
# $ri.
proc ::ptjd::read-tables {until data ptr qts huffdc huffac ri} {
    while {[llength $qts] < 4} {
        lappend qts {}
    }
    while {[llength $huffdc] < 4} {
        lappend huffdc {}
    }
    while {[llength $huffac] < 4} {
        lappend huffac {}
    }

    while 1 {
        scan-at-ptr {a2 Su} marker length
        switch -exact -- $marker {
            \xFF\xDB {
                # Quantization table.
                incr ptr 4
                set scanned 2

                while {$scanned < $length} {
                    scan-at-ptr {cu cu64} pqtq elements
                    incr ptr 65
                    incr scanned 65
                    lassign [hi-lo $pqtq] pq tq
                    if {$pq == 1} {
                        error "16-bit quantization tables aren't supported"
                    }
                    lset qts $tq $elements
                }
            }
            \xFF\xC4 {
                # Huffman table.
                incr ptr 4
                set scanned 2

                while {$scanned < $length} {
                    scan-at-ptr {cu cu16} tcth bits
                    incr scanned 17
                    incr ptr 17
                    lassign [hi-lo $tcth] tc th
                    set huffval {}
                    foreach li $bits {
                        scan-at-ptr cu$li ln
                        incr ptr $li
                        lappend huffval $ln
                        incr scanned $li
                    }
                    if {$tc == 0} {
                        lset huffdc $th [generate-huffman-codes $huffval]
                    } else {
                        lset huffac $th [generate-huffman-codes $huffval]
                    }
                }
            }
            \xFF\xDD {
                # Define Restart Interval.
                incr ptr 2
                scan-at-ptr {Su Su} lr ri
                assert-equal $lr 4
                incr ptr 4
            }
            default {
                if {$marker eq $until} {
                    break
                } elseif {(("\xFF\xE0" <= $marker) && ($marker <= "\xFF\xEF"))
                          || ($marker eq "\xFF\xFE")} {
                    # Skip APP0-APPF sections and comments. APP0 is the JFIF
                    # header, APP1 is the EXIF header, APPE is Adobe info.
                    incr ptr [expr {$length + 2}]
                } else {
                    error "unsupported section \"[escape-unprintable $marker]\"\
                           at 0x[format %x $ptr]"
                }
            }
        }
    }

    return [list $ptr $qts $huffdc $huffac $ri]
}

proc ::ptjd::read-frame-header {data ptr} {
    scan-at-ptr {a2 Su} marker length
    assert-equal $marker \xFF\xC0
    incr ptr 4
    scan-at-ptr {cu Su Su cu} p y x nf
    incr ptr 6
    set components {}
    for {set i 0} {$i < $nf} {incr i} {
        scan-at-ptr {cu cu cu} c hv tq
        incr ptr 3
        lassign [hi-lo $hv] h v
        lappend components [dict create c $c h $h v $v tq $tq]
    }
    return [list $ptr [dict create p $p y $y x $x nf $nf \
                                   components $components]]
}
proc ::ptjd::read-scan-header {data ptr} {
    scan-at-ptr {a2 Su} marker _
    assert-equal $marker \xFF\xDA
    incr ptr 4
    scan-at-ptr cu ns
    incr ptr 1
    set components {}
    for {set i 1} {$i <= $ns} {incr i} {
        scan-at-ptr {cu cu} cs tdta
        incr ptr 2
        lassign [hi-lo $tdta] td ta
        lappend components [dict create cs $cs td $td ta $ta]
    }
    scan-at-ptr {cu cu cu} ss se ahal
    incr ptr 3
    lassign [hi-lo $ahal] ah al
    return [list $ptr [dict create ns $ns components $components \
                                   ss $ss se $se ah $ah al $al]]
}

# Read $n bits from $bits. If there aren't $n bits in $bits, read enough bytes
# from $data starting at $ptr into $bits and advance $ptr accordingly. Escaped
# \xFF values are accounted for. Return the updated $ptr and $bits, and the $n
# read bits.
proc ::ptjd::get-bits {data ptr bits n} {
    while {[llength $bits] < $n} {
        scan-at-ptr B8 byte
        if {$byte eq "11111111"} {
            incr ptr
            scan-at-ptr H2 second
            switch -exact -- $second {
                00 {
                    # The value \xFF was escaped as \xFF\x00.
                }
                d0 -
                d1 -
                d2 -
                d3 -
                d4 -
                d5 -
                d6 -
                d7 {
                    # Skip the restart marker.
                    incr ptr
                    continue
                }
                d9 {
                    error {encountered EOI}
                }
                default {
                    error "can't understand marker 0xff$second\
                           at 0x[format %x $ptr]"
                }
            }
        }
        lappend bits {*}[split $byte {}]
        incr ptr
    }
    set result [lrange $bits 0 $n-1]
    set bits [lrange $bits $n end]
    return [list $ptr $bits $result]
}

# Read one Huffman code from $data. Return the associated value.
proc ::ptjd::read-code {data ptr bits table {ct ""}} {
    set code {}
    while {![dict exists $table $code]} {
        if {$bits eq {}} {
            lassign [get-bits $data $ptr $bits 1] ptr bits bit
        } else {
            set bits [lassign $bits bit]
        }
        append code $bit
        if {[bytelength $code] > 16} {
            error "can't decode the [concat $ct code] \"$code\"\
                   at 0x[format %x $ptr] ($table)"
        }
    }
    return [list $ptr $bits [dict get $table $code]]
}

# Take a list of N bits and return a signed integer in the range
# -2^N + 1 .. -2^(N - 1), 2^(N - 1) .. 2^N - 1 per the JPEG standard.
# See "Table 5 - Huffman DC Value Encoding" at
# http://www.impulseadventure.com/photo/jpeg-huffman-coding.html
proc ::ptjd::restore-signed x {
    if {$x eq {}} {
        return 0
    } elseif {[lindex $x 0] == 0} {
        return [expr -0b[string map {0 1 1 0} [join $x {}]]]
    } else {
        return [expr 0b[join $x {}]]
    }
}

# Read one block.
proc ::ptjd::read-block {data ptr bits dct act {compN ""}} {
    # The DC component.
    set value {}
    lassign [read-code $data $ptr $bits $dct [concat $compN DC]] ptr bits value

    set dc 0
    if {$value > 0} {
        lassign [get-bits $data $ptr $bits $value] ptr bits dc
        set dc [restore-signed $dc]
    }

    # The AC component.
    set ac {}
    while {[llength $ac] < 63} {
        lassign [read-code $data $ptr $bits $act [concat $compN AC]] \
                ptr bits rs
        if {$rs == 0x00} {
            # End of Block.
            break
        } elseif {$rs == 0xF0} {
            # ZRL -- sixteen zeros.
            lappend ac 0 0 0 0  0 0 0 0  0 0 0 0  0 0 0 0
        } else {
            lassign [hi-lo $rs] r s
            for {set i 0} {$i < $r} {incr i} {
                lappend ac 0
            }

            set c 0
            if {$s > 0} {
                lassign [get-bits $data $ptr $bits $s] ptr bits c
            }
            lappend ac [restore-signed $c]
        }
    }
    while {[llength $ac] < 63} {
        lappend ac 0
    }
    set block [concat $dc $ac]
    return [list $ptr $bits $block]
}

proc ::ptjd::dequantize-block {block qt} {
    set result {}
    assert-equal [llength $block] [llength $qt]
    foreach x $block y $qt {
        lappend result [expr {$x * $y}]
    }
    return $result
}

proc ::ptjd::unzigzag block {
    set zigzag {
         0  1  5  6 14 15 27 28
         2  4  7 13 16 26 29 42
         3  8 12 17 25 30 41 43
         9 11 18 24 31 40 44 53
        10 19 23 32 39 45 52 54
        20 22 33 38 46 51 55 60
        21 34 37 47 50 56 59 61
        35 36 48 49 57 58 62 63
    }
    set reordered {}
    foreach i $zigzag {
        lappend reordered [lindex $block $i]
    }
    return $reordered
}

proc ::ptjd::inverse-dct block {
    set result {}
    set m $::ptjd::inverseDctMatrix
    for {set y 0} {$y < 8} {incr y} {
        for {set x 0} {$x < 8} {incr x} {
            set sum 0
            for {set u 0} {$u < 8} {incr u} {
                set c1 [lindex $m [expr {8*$x + $u}]]
                for {set v 0} {$v < 8} {incr v} {
                    set sum [expr {
                        $sum + $c1*[lindex $block [expr {8*$v + $u}]]
                                  *[lindex $m [expr {8*$y + $v}]]
                    }]
                }
            }
            lappend result [expr {round($sum/4.0)}]
        }
    }
    return $result
}

# Return the number of blocks horizontally or vertically in an image component
# given the matching number of pixels, the scaling factor and the maximum
# horizontal/vertical scaling factor for the image as a whole.
proc ::ptjd::block-count {pixels scale max} {
    set count [expr {($pixels + (8 * $max - 1))/(8*$max)*$max/$scale}]
    if {$count == 0} { set count 1 }
    return $count
}

# A helper proc for [combine-blocks].
proc ::ptjd::put-block {offset block} {
    upvar 1 plane plane
    for {set j 0} {$j < 64} {incr j 8} {
        set y [expr {$offset + $j/8}]
        lappend plane($y) {*}[lrange $block $j $j+7]
    }
}

# Combine the blocks in $blocks into a color plane. $hor and $vert are the
# horizontal and vertical block count respectively and $h and $v are the
# corresponding scaling factors.
proc ::ptjd::combine-blocks {hor vert h v blocks} {
    assert-equal [llength $blocks] [expr {$hor * $vert}]
    for {set i 0} {$i < 8*$vert} {incr i} {
        set plane($i) {}
    }

    set i 0
    for {set vPos 0} {$vPos < $vert} {incr vPos $v} {
        for {set hPos 0} {$hPos < $hor} {incr hPos $h} {
            for {set vOffset 0} {$vOffset < $v} {incr vOffset} {
                for {set hOffset 0} {$hOffset < $h} {incr hOffset} {
                    put-block [expr {($vPos + $vOffset)*8}] [lindex $blocks $i]
                    incr i
                }
            }
        }
    }

    set result {}
    for {set i 0} {$i < 8*$vert} {incr i} {
        lappend result {*}$plane($i)
    }
    assert-equal [llength $result] [expr {[llength $blocks] * 64}]
    return $result
}

# Crudely upscale a color plane by duplicating values. Each of $scaleH and
# $scaleV should be either 1 (no upscaling) or 2 (upscale in this direction).
proc ::ptjd::scale-double {hor vert scaleH scaleV plane} {
    if {($scaleH ni {1 2})} {
        error "scaleH should be 1 or 2 (\"$scaleH\" given)"
    }
    if {($scaleV ni {1 2})} {
        error "scaleV should be 1 or 2 (\"$scaleV\" given)"
    }
    if {($scaleH == 1) && ($scaleV == 1)} { return $plane }
    set hor8 [expr {$hor*8}]
    for {set i 0} {$i < $hor8*$vert*8} {incr i $hor8} {
        set line [lrange $plane $i [expr {$i + $hor8 - 1}]]
        if {$scaleH == 2} {
            set scaled {}
            foreach c $line {
                lappend scaled $c $c
            }
            set line $scaled
        }
        lappend result {*}$line
        if {$scaleV == 2} {
            lappend result {*}$line
        }
    }
    assert-equal [expr {$scaleH*$scaleV*[llength $plane]}] [llength $result]
    return $result
}

# Upscale a color plane somewhat less crudely. Each of $scaleH and $scaleV
# should be either 1 (no upscaling) or 2 (upscale in this direction).
proc ::ptjd::scale-linear {hor vert scaleH scaleV plane} {
    if {($scaleH ni {1 2})} {
        error "scaleH should be 1 or 2 (\"$scaleH\" given)"
    }
    if {($scaleV ni {1 2})} {
        error "scaleV should be 1 or 2 (\"$scaleV\" given)"
    }
    if {($scaleH == 1) && ($scaleV == 1)} { return $plane }
    set hor8 [expr {$hor*8}]
    set prevLine {}
    for {set i 0} {$i < $hor8*$vert*8} {incr i $hor8} {
        set line [lrange $plane $i [expr {$i + $hor8 - 1}]]
        if {$scaleH == 2} {
            set scaled {}
            set prevC [lindex $line 0]
            foreach c $line {
                lappend scaled [expr {($prevC + $c) / 2}] $c
                set prevC $c
            }
            set line $scaled
        }
        if {$prevLine eq {}} { set prevLine $line }
        if {$scaleV == 1} {
            lappend result {*}$line
        } else { ;# $scaleV == 2
            set interp {}
            foreach c1 $prevLine c2 $line {
                lappend interp [expr {($c1 + $c2) / 2}]
            }
            set prevLine $line
            lappend result {*}$interp {*}$line
        }
    }
    assert-equal [expr {$scaleH*$scaleV*[llength $plane]}] [llength $result]
    return $result
}

# Crop a color plane to $width by $height.
proc ::ptjd::crop {hor width height plane} {
    set hor8 [expr {$hor*8}]
    set result {}
    for {set i 0} {$i < $hor8*$height} {incr i $hor8} {
        lappend result {*}[lrange $plane $i [expr {$i + $width - 1}]]
    }
    return $result
}

proc ::ptjd::clamp value {
    if {$value < 0} {
        return 0
    } elseif {$value > 255} {
        return 255
    } else {
        return $value
    }
}

proc ::ptjd::ycbcr-to-rgb {y cb cr} {
    set r [clamp [expr {
        round($y +                      + 1.402   *($cr - 128))
    }]]
    set g [clamp [expr {
        round($y - 0.344136*($cb - 128) - 0.714136*($cr - 128))
    }]]
    set b [clamp [expr {
        round($y + 1.772   *($cb - 128)                       )
    }]]
    return [list $r $g $b]
}

proc ::ptjd::decode {data {scaler ::ptjd::scale-double}} {
    set ptr 0
    set length [bytelength $data]

    # Start of Image.
    scan-at-ptr a2 soi
    assert-equal $soi \xFF\xD8
    incr ptr 2

    set qts {}    ;# Quantization tables.
    set huffdc {} ;# Huffman DC tables.
    set huffac {} ;# Huffman AC tables.
    set ri {}     ;# Restart interval.

    # Parse tables until a Start of Frame marker is encountered.
    lassign [read-tables \xFF\xC0 $data $ptr $qts $huffdc $huffac $ri] \
            ptr qts huffdc huffac ri

    lassign [read-frame-header $data $ptr] ptr frame
    if {[dict get $frame nf] ni {1 3}} {
        error "unexpected number of components: [dict get $frame nf]"
    }

    # The scan loop.

    # Parse tables until a Start of Scan marker is encountered.
    lassign [read-tables \xFF\xDA $data $ptr $qts $huffdc $huffac $ri] \
            ptr qts huffdc huffac ri
    # Start of Scan.
    lassign [read-scan-header $data $ptr] ptr scan

    # Read and decode the MCUs of the image.
    set bits {} ;# A bit buffer for [get-bits] and procs that use it.
    for {set i 1} {$i <= [dict get $frame nf]} {incr i} {
        set prevDc($i) 0
        set planeBlocks($i) {}
        incr i -1
        set component [lindex [dict get $frame components] $i]
        set repeats [expr {[dict get $component h]*[dict get $component v]}]
        lappend scanOrder {*}[lrepeat $repeats $i]
        incr i
    }
    unset component repeats
    set rc 0 ;# Restart count.
    while 1 {
        # Read an MCU.
        foreach i $scanOrder {
            # Read a block.
            set scanComp [lindex [dict get $scan components] $i]
            set cs [dict get $scanComp cs]
            set dct [lindex $huffdc [dict get $scanComp td]]
            set act [lindex $huffac [dict get $scanComp ta]]
            lassign [read-block $data $ptr $bits $dct $act \
                                "cs [expr {$i + 1}]"] \
                    ptr bits block

            # Transform a DC diff into a DC value.
            set dcv [lindex $block 0]
            incr dcv $prevDc($cs)
            set prevDc($cs) $dcv
            lset block 0 $dcv

            # Dequantize the block.
            set frameComp [lindex [dict get $frame components] $i]
            set qt [lindex $qts [dict get $frameComp tq]]
            set blockDq [dequantize-block $block $qt]
            unset block

            # Reorder the block.
            set blockReord [unzigzag $blockDq]
            unset blockDq

            # Apply an inverse DCT to the block.
            set blockSpatDom [inverse-dct $blockReord]
            unset blockReord
            lappend planeBlocks($cs) $blockSpatDom

        }

        incr rc
        if {($ri ne {}) && ($rc == $ri)} {
            for {set j 1} {$j <= [dict get $frame nf]} {incr j} {
                set prevDc($j) 0
            }
            set bits {}
            set rc 0
        }
        # End of Image.
        scan-at-ptr a2 eoi
        if {$eoi eq "\xFF\xD9"} break
    }

    # Combine 8x8 blocks into planes.
    set planes {}
    set width  [dict get $frame x]
    set height [dict get $frame y]
    set maxH 0
    set maxV 0
    for {set i 1} {$i <= [dict get $frame nf]} {incr i} {
        set component [lindex [dict get $frame components] [expr {$i - 1}]]
        set h [dict get $component h]
        set v [dict get $component v]
        if {$h > $maxH} { set maxH $h }
        if {$v > $maxV} { set maxV $v }
    }
    for {set i 1} {$i <= [dict get $frame nf]} {incr i} {
        set component [lindex [dict get $frame components] [expr {$i - 1}]]
        set h [dict get $component h]
        set v [dict get $component v]
        set scaleH [expr {$maxH/$h}]
        set scaleV [expr {$maxV/$v}]
        set horBlocks  [block-count $width  $scaleH $maxH]
        set vertBlocks [block-count $height $scaleV $maxV]
        unset component
        set plane [combine-blocks $horBlocks $vertBlocks $h $v \
                                  $planeBlocks($i)]
        unset planeBlocks($i)
        set shifted {}
        foreach x $plane {
            lappend shifted [clamp [expr {$x + 128}]]
        }
        unset plane
        set scaled [$scaler $horBlocks $vertBlocks $scaleH $scaleV $shifted]
        unset shifted
        lappend planes [crop [expr {$scaleH*$horBlocks}] $width $height $scaled]
    }

    if {[dict get $frame nf] == 1} {
        set decoded [lindex $planes 0]
    } else { ;# nf == 3
        set decoded {}
        foreach  y [lindex $planes 0] \
                cb [lindex $planes 1] \
                cr [lindex $planes 2] {
            lappend decoded {*}[ycbcr-to-rgb $y $cb $cr]
        }
    }
    return [list [dict get $frame x] \
                 [dict get $frame y] \
                 [dict get $frame nf] \
                 $decoded]
}

proc ::ptjd::image-to-ppm {width height color data} {
    return "P[expr {$color == 1 ? 2 : 3}]\n$width $height\n255\n$data"
}

proc ::ptjd::ppm-to-image ppm {
    scan $ppm "P%u\n%u %u\n255\n%n" format width height offset
    set data {}
    # Remove whitespace.
    foreach x [string range $ppm $offset end] {
        lappend data $x
    }
    if {$format == 2} {
        set color 1
    } elseif {$format == 3} {
        set color 3
    } else {
        error "only P2 and P3 are supported (\"$format\" given)"
    }
    if {$color == 1} {
        assert-equal [llength $data] [expr {$width * $height}]
    } else {
        assert-equal [llength $data] [expr {$width * $height * 3}]
    }
    return [list $width $height $color $data]
}

namespace eval ::ptjd::demo {}

proc ::ptjd::demo::main {argv0 argv} {
    if {[llength $argv] != 1} {
        puts stderr "usage: $argv0 filename.jpg \[> filename.ppm\]"
        exit 1
    }
    lassign $argv filename
    set h [open $filename rb]
    set data [read $h]
    close $h
    puts [::ptjd::image-to-ppm {*}[::ptjd::decode $data]]
}

# If this is the main script...
if {[info exists argv0] && ([file tail [info script]] eq [file tail $argv0])} {
    ::ptjd::demo::main $argv0 $argv
}
