using System;
using System.Runtime.InteropServices;

public static class PeakMeter
{
    // NOTE: the real vtable order is EnumAudioEndpoints, GetDefaultAudioEndpoint,
    // GetDevice, Register..., Unregister... (NOT the alphabetical docs order).
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int dwStateMask, out IntPtr ppDevices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IntPtr ppEndpoint);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string pwstrId, out IntPtr ppDevice);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr pClient);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr pClient);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, out IntPtr ppInterface);
        [PreserveSig] int OpenPropertyStore(int stgmAccess, out IntPtr ppProperties);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
        [PreserveSig] int GetState(out int pdwState);
    }

    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioMeterInformation
    {
        [PreserveSig] int GetPeakValue(out float pfPeak);
        [PreserveSig] int GetMeteringChannelCount(out int pnChannelCount);
        [PreserveSig] int GetChannelsPeakValues(int u32ChannelCount, [Out] float[] afPeakValues);
        [PreserveSig] int QueryHardwareSupport(out int pdwHardwareSupportMask);
    }

    private static IAudioMeterInformation _meter;
    public static string LastError = "";

    public static bool Init()
    {
        try
        {
            Type t = Type.GetTypeFromCLSID(new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"));
            var en = (IMMDeviceEnumerator)Activator.CreateInstance(t);

            IntPtr devPtr;
            int hr = en.GetDefaultAudioEndpoint(0, 0, out devPtr); // eRender, eConsole
            if (hr != 0 || devPtr == IntPtr.Zero) { LastError = "GetDefaultAudioEndpoint hr=0x" + hr.ToString("X8"); return false; }

            var dev = (IMMDevice)Marshal.GetObjectForIUnknown(devPtr);
            Guid iid = typeof(IAudioMeterInformation).GUID;
            IntPtr meterPtr;
            hr = dev.Activate(ref iid, 23, IntPtr.Zero, out meterPtr); // CLSCTX_ALL
            if (hr != 0 || meterPtr == IntPtr.Zero) { LastError = "Activate hr=0x" + hr.ToString("X8"); return false; }

            _meter = (IAudioMeterInformation)Marshal.GetObjectForIUnknown(meterPtr);
            return true;
        }
        catch (Exception e)
        {
            LastError = e.GetType().Name + ": " + e.Message;
            return false;
        }
    }

    public static float Peak()
    {
        try
        {
            if (_meter == null) return -1f;
            float p;
            int hr = _meter.GetPeakValue(out p);
            return hr == 0 ? p : -1f;
        }
        catch { return -1f; }
    }
}
