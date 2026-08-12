// The reference half of tools/dspdiff.py.
//
// Drives blargg's S-DSP with a script of register writes read from stdin --
// one "sample register value" per line -- and prints ENVX, OUTX and ENDX after
// every sample.  Those are the three registers a program can read back, so
// what this prints is what a game could see.
//
// It is not built here, because the reference is not in this repository:
//
//     git clone https://github.com/blarggs-audio-libraries/snes_spc
//     cp tools/dspprobe.cpp snes_spc/snes_spc/
//     cd snes_spc/snes_spc && g++ -O2 -o dspprobe dspprobe.cpp SPC_DSP.cpp
#include "SPC_DSP.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>

static unsigned char ram[0x10000];

int main(int argc, char** argv)
{
    SPC_DSP dsp;
    dsp.init(ram);
    dsp.reset();
    memset(ram, 0, sizeof ram);

    // One BRR block that loops on itself, matching what dspdiff.py sets up.
    ram[0x200] = 0x00; ram[0x201] = 0x02;
    ram[0x202] = 0x00; ram[0x203] = 0x02;
    ram[0x204] = 0xB3;
    for (int i = 0; i < 8; i++)
        ram[0x205 + i] = 0x77;

    short out[64];
    int samples = argc > 1 ? atoi(argv[1]) : 160;

    struct W { int at, reg, val; };
    static W writes[4096];
    int nw = 0;
    while (nw < 4096 && scanf("%d %i %i", &writes[nw].at, &writes[nw].reg, &writes[nw].val) == 3)
        nw++;

    int w = 0;
    for (int s = 0; s < samples; s++) {
        while (w < nw && writes[w].at == s) {
            dsp.write(writes[w].reg, writes[w].val);
            w++;
        }
        dsp.set_output(out, 64);
        dsp.run(32);
        printf("%d %02X %02X %02X\n", s, dsp.read(0x08), dsp.read(0x09), dsp.read(0x7C));
    }
    return 0;
}
