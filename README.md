# Pure Tcl JPEG decoder

![An abstract image of four by four color tiles used to test PTJD.](test-data/restart.jpg)

A single-file pure Tcl baseline JPEG decoder library.
Works in Tcl 8.5, Tcl 8.6, Tcl 9, and Jim Tcl 0.75 and later.

## Q & A

### What is supported?

- JPEG/JFIF and JPEG/Exif
- Huffman coding
- YCbCy (standard three-channel color) and grayscale
- 8-bit color channels
- Chroma subsampling (horizontal and vertical 4:2:2 subsampling and 4:2:0 subsampling has been tested)
- Restart markers

### What isn't?

- Progressive and lossless encoding
- Arithmetic coding
- CMYK color
- 12-bit color channels

### Why?

To learn how to write a JPEG decoder.

### What is it good for?

The decoder is too slow to replace JPEG decoders for Tcl written in C for anything but the smallest images.
However, it can be used as a benchmark to compare different Tcl implementations and different versions of the same implementation.
(See [below](#what-is-the-performance-like).)
The code may help you understand JPEG compression.
It is small (around 850 lines),
written in a [functional](https://en.wikipedia.org/wiki/Functional_programming) style
(the decoder consists of pure functions [insofar as they exist](https://wiki.tcl-lang.org/page/trace) in Tcl),
and stores data in easy-to-inspect immutable data structures.

(If you want to understand how a JPEG decoder works,
based on my experience I recommend reading the [Wikipedia article on JPEG](https://en.wikipedia.org/wiki/JPEG)
and following the [JPEG Huffman coding tutorial](https://web.archive.org/web/20190118205958/https://www.impulseadventure.com/photo/jpeg-huffman-coding.html) by Calvin Hass before anything else.
If you don't know Tcl and want to read the code, [Learn Tcl in Y Minutes](https://learnxinyminutes.com/docs/tcl/) should teach you enough to get started.
Tcl is pretty much a collection of independent commands;
once you know the syntax, you can [look them up](https://www.tcl.tk/man/tcl8.6/TclCmd/contents.htm) as you go.)

### What is the performance like?

The script `benchmark.tcl` can evaluate the performance of the decoder by timing how long it takes to decode several test images included in the repository.
Here are the results gathered on an [AMD Phenom II](https://www.cpubenchmark.net/cpu.php?cpu=AMD+Phenom+II+X4+955&id=368) CPU.

```none
Running in Tcl 8.5.19 (64-bit) on x86_64 Linux
5 iterations per image
==========================
grayscale.jpg        10 ms
landscape.jpg     19548 ms
landscape-q.jpg   11159 ms
63.6 MB
```

```none
Running in Tcl 8.6.5 (64-bit) on x86_64 Linux
5 iterations per image
==========================
grayscale.jpg        10 ms
landscape.jpg     18758 ms
landscape-q.jpg   10587 ms
75.3 MB
```

```none
Running in Jim 0.75 (64-bit) on x86_64 linux
5 iterations per image
==========================
grayscale.jpg        19 ms
landscape.jpg     38508 ms
landscape-q.jpg   22832 ms
88.8 MB
```

## License

MIT.

The `test-data/landscape*` photo by [m wrona](https://unsplash.com/@mwrona), licensed under [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
