using System;
using System.IO;

// Renders a rank-up WAV with the user's volume applied, into a copy.
// System.Media.SoundPlayer has no volume control, so the samples are scaled
// here instead.
//
// Two-stage gain:
//   1) every rank file is normalised to the same peak (0.95 full scale),
//      because D/C/B are mixed much quieter than S/SS/SSS and the user
//      hears "the default volume is too small" on D;
//   2) the user volume (0..2.0 = 0..200%) is applied on top.
// Samples are clamped to int16, so volumes above 100% can clip/distort.
public static class WavGain
{
    private const double TARGET_PEAK = 0.95;

    public static bool Convert(string inputPath, string outputPath, double gain)
    {
        byte[] b = File.ReadAllBytes(inputPath);
        if (b.Length < 44) return false;
        if (b[0] != (byte)'R' || b[1] != (byte)'I' || b[2] != (byte)'F' || b[3] != (byte)'F') return false;
        if (b[8] != (byte)'W' || b[9] != (byte)'A' || b[10] != (byte)'V' || b[11] != (byte)'E') return false;

        int pos = 12;
        int dataPos = -1;
        int dataLen = 0;
        bool pcm16 = false;
        while (pos + 8 <= b.Length)
        {
            string id = "" + (char)b[pos] + (char)b[pos + 1] + (char)b[pos + 2] + (char)b[pos + 3];
            int size = BitConverter.ToInt32(b, pos + 4);
            if (size < 0) return false;
            if (id == "fmt ")
            {
                if (size < 16 || pos + 24 > b.Length) return false;
                int format = BitConverter.ToInt16(b, pos + 8);
                int bits = BitConverter.ToInt16(b, pos + 22);
                pcm16 = (format == 1 && bits == 16);
            }
            else if (id == "data")
            {
                dataPos = pos + 8;
                dataLen = size;
                if (dataPos + dataLen > b.Length) dataLen = b.Length - dataPos;
                break;
            }
            pos += 8 + size + (size & 1);
        }
        if (!pcm16 || dataPos < 0 || dataLen <= 0) return false;

        if (gain < 0) gain = 0;
        if (gain > 4) gain = 4;

        // Peak of this file, for the loudness normalisation.
        int maxAbs = 0;
        for (int i = 0; i + 1 < dataLen; i += 2)
        {
            short s0 = (short)(b[dataPos + i] | (b[dataPos + i + 1] << 8));
            int a0 = s0 < 0 ? -s0 : s0;
            if (a0 > maxAbs) maxAbs = a0;
        }
        if (maxAbs <= 0) return false;

        double total = gain * (TARGET_PEAK * 32767.0 / maxAbs);
        int last = -1;
        for (int i = 0; i + 1 < dataLen; i += 2)
        {
            short s = (short)(b[dataPos + i] | (b[dataPos + i + 1] << 8));
            int v = (int)(s * total);
            if (v > 32767) v = 32767; else if (v < -32768) v = -32768;
            byte lo = (byte)(v & 0xFF);
            byte hi = (byte)((v >> 8) & 0xFF);
            b[dataPos + i] = lo;
            b[dataPos + i + 1] = hi;
            last = v;
        }
        if (last == -1) return false;

        File.WriteAllBytes(outputPath, b);
        return true;
    }
}
