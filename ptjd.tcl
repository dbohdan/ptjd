# PTJD, a pure Tcl (baseline) JPEG decoder.
# Copyright (c) 2017 dbohdan and contributors listed in AUTHORS
# License: MIT.
namespace eval ::ptjd {
    variable version 0.1.0
    variable inverseDctMatrix {}

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

proc ::ptjd::assert-equal {actual expected} {
    if {$actual ne $expected} {
        error "expected \"[binary encode hex $expected]\",\
               but got \"[binary encode hex $actual]\""
    }
}

proc ::ptjd::scan-at-ptr {format args} {
    upvar 1 data data ptr ptr
    foreach varName $args {
        upvar 1 $varName $varName
    }
    binary scan $data [concat @$ptr $format] {*}$args
}

proc ::ptjd::hi-lo byte {
    set byte [expr {$byte & 0xFF}]
    return [list [expr {$byte >> 4}] [expr {$byte & 0x0F}]]
}

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
            if {$used} continue
            set values [lassign $values value]
            dict set codes [format %0${i}b $j] $value
            lappend prefixes $i $j
        }
        if {$values ne {}} {
            error "couldn't assign codes to values [list $values] (length $i)"
        }
    }
    return $codes
}

proc ::ptjd::read-tables {until data ptr qts huffdc huffac} {
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
                    lset huff[expr {$tc == 0 ? "dc" : "ac"}] \
                         $th \
                         [generate-huffman-codes $huffval]
                }
            }
            default {
                if {$marker eq $until} {
                    break
                } elseif {("\xFF\xE0" <= $marker) && ($marker <= "\xFF\xEF")} {
                    # Skip APP0-APPF sections. APP0 is the JFIF header, APP1 is
                    # the EXIF header, APPE is Adobe info.
                    incr ptr [expr {$length + 2}]
                } else {
                    error "unsupported section \"[binary encode hex $marker]\"\
                           at 0x[format %x $ptr]"                    
                }
            }
        }
    }

    return [list $ptr $qts $huffdc $huffac]
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

proc ::ptjd::get-bit {data ptr bits} {
    if {$bits eq {}} {
        scan-at-ptr B8 bits
        if {$bits eq "11111111"} {
            incr ptr 
            scan-at-ptr H2 second
            switch -exact -- $second {
                00 {
                    # The value \xFF was escaped as \xFF\x00.
                }
                d9 {
                    incr ptr -1
                    return [list $ptr {} EOI]
                }
                default {
                    error "can't understand marker 0xff$second\
                           at 0x[format %x $ptr]"
                }
            }
        }
        set bits [split $bits {}]
        incr ptr
    }
    set bits [lassign $bits bit]
    return [list $ptr $bits $bit]
}

# Read one Huffman code from $data. Return the associated value.
proc ::ptjd::read-code {data ptr bits table {ct ""}} {
    set code {}
    while {![dict exists $table $code]} {
        lassign [get-bit $data $ptr $bits] ptr bits bit
        if {$bit eq "EOI"} {
            return [list $ptr $bits EOI]
        } else {
            append code $bit
        }
        if {[string length $code] > 16} {
            error "can't decode the [concat $ct code] \"$code\"\
                   at 0x[format %x $ptr] ($table)"
        }
    }
    return [list $ptr $bits [dict get $table $code]]
}

proc ::ptjd::restore-signed x {
    if {$x eq {}} {
        return 0
    } elseif {[string index $x 0] == 0} {
        return [expr -0b[string map {0 1 1 0} $x]]
    } else {
        return [expr 0b$x]
    }
}

proc ::ptjd::read-block {data ptr bits dct act {compN ""}} {
    # The DC component.
    set value {}
    lassign [read-code $data $ptr $bits $dct [concat $compN DC]] ptr bits value
    if {$value eq "EOI"} {
        return [list $ptr $bits {}]
    }
    set dc {}
    for {set i 0} {$i < $value} {incr i} {
        lassign [get-bit $data $ptr $bits] ptr bits bit
        append dc $bit
    }
    set dc [restore-signed $dc]

    # The AC component.
    set ac {}
    while {[llength $ac] < 63} {
        lassign [read-code $data $ptr $bits $act [concat $compN AC]] \
                ptr bits rs
        if {$rs eq "EOI"} {
            break
        } elseif {$rs == 0x00} {
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
            set c {}
            for {set i 0} {$i < $s} {incr i} {
                lassign [get-bit $data $ptr $bits] ptr bits bit
                append c $bit
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
                        $sum + $c1*[lindex $block [expr {8*$v + $u}]]*
                                   [lindex $m [expr {8*$y + $v}]]
                    }]
                }
            }
            lappend result [expr {round($sum / 4.0)}]
        }   
    }
    return $result
}

# Combine the blocks in $blocks into a plane and crop it to $width by $height.
proc ::ptjd::combine-blocks {width height blocks} {
    set hor  [expr {($width  + 7)/8}]
    set vert [expr {($height + 7)/8}]
    assert-equal [llength $blocks] [expr {$hor * $vert}]
    for {set i 0} {$i < 8*$vert} {incr i} {
        set plane($i) {}
    }
    set i 0
    foreach block $blocks {
        for {set j 0} {$j < 64} {incr j 8} {
            set y [expr {$i/$hor*8 + $j/8}]
            lappend plane($y) {*}[lrange $block $j $j+7]
        }
        incr i
    }
    set result {}
    for {set i 0} {$i < $height} {incr i} {
        lappend result {*}[lrange $plane($i) 0 $width-1]
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

proc ::ptjd::ycbcr2rgb {y cb cr} {
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

proc ::ptjd::decode data {
    set ptr 0
    set length [string length $data]

    # Start of Image.
    scan-at-ptr a2 soi
    assert-equal $soi \xFF\xD8
    incr ptr 2

    set qts {}
    set huffdc {}
    set huffac {}

    # Parse tables until a Start of Frame marker is encountered.
    lassign [read-tables \xFF\xC0 $data $ptr $qts $huffdc $huffac] \
            ptr qts huffdc huffac

    lassign [read-frame-header $data $ptr] ptr frame
    if {[dict get $frame nf] ni {1 3}} {
        error "unexpected number of components: [dict get $frame nf]"
    }

    # The scan loop.

    # Parse tables until a Start of Scan marker is encountered.
    lassign [read-tables \xFF\xDA $data $ptr $qts $huffdc $huffac] \
            ptr qts huffdc huffac

    # Start of Scan.
    lassign [read-scan-header $data $ptr] ptr scan

    # Read and decode the MCUs of the image.
    set bits {} ;# For the proc get-bit.
    set scanOrder {}
    for {set i 1} {$i <= [dict get $frame nf]} {incr i} {
        set prevDc($i) 0
        set planeBlocks($i) {}
        lappend scanOrder $i
    }
    while 1 {
        for {set i 0} {$i < [dict get $scan ns]} {incr i} {
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
        # End of Image.
        scan-at-ptr a2 eoi
        if {$eoi eq "\xFF\xD9"} break
    }

    # Combine 8x8 blocks into planes.
    set planes {}
    for {set i 1} {$i <= [dict get $frame nf]} {incr i} {
        set plane [combine-blocks [dict get $frame x] \
                                  [dict get $frame y] \
                                  $planeBlocks($i)]
        unset planeBlocks($i)
        set shifted {}
        foreach x $plane {
            lappend shifted [clamp [expr {$x + 128}]]
        }
        unset plane
        lappend planes $shifted
    }

    if {[dict get $frame nf] == 1} {
        set decoded [lindex $planes 0]
    } else { ;# nf == 3
        set decoded {}
        foreach  y [lindex $planes 0] \
                cb [lindex $planes 1] \
                cr [lindex $planes 2] {
            lappend decoded {*}[ycbcr2rgb $y $cb $cr]
        }
    }
    return [list [dict get $frame x] \
                 [dict get $frame y] \
                 [dict get $frame nf] \
                 $decoded]
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
    lassign [::ptjd::decode $data] width height color data
    puts "P[expr {$color == 1 ? 2 : 3}]\n$width $height\n255\n$data"
}

# If this is the main script...
if {[info exists argv0] && ([file tail [info script]] eq [file tail $argv0])} {
    ::ptjd::demo::main $argv0 $argv
}
