#!/usr/bin/env python3
"""Copia uma imagem por modelo do pacote do NGENUITY (Assets/Devices) para o
LowerX, reduzida para no máximo 800 px. O nome do arquivo é o `model` do
DeviceCatalog. Uso: prepare_device_images.py <Assets/Devices> <destino>"""
import os, subprocess, sys

IMAGES = {
    "KeyboardAlloyElite_II": "AlloyEliteII/KeyboardAlloyEliteII104_US_Black.png",
    "KeyboardAlloyElite": "AlloyElite/US.png",
    "KeyboardAlloyFPS": "AlloyFPS/KeyboardAlloyFPS104_US.png",
    "KeyboardAlloyMKW100": "AlloyMKW100/US.png",
    "KeyboardAlloyOrigins60": "AlloyOrigins60/Black_Black/US.png",
    "KeyboardAlloyOrigins65": "AlloyOrigins65/US.png",
    "KeyboardAlloyOriginsCore": "AlloyOriginsCore/KeyboardAlloyOriginsCore87_US.png",
    "KeyboardAlloyOrigins": "AlloyOrigins/KeyboardAlloyOrigins104.png",
    "UniversalKeyboardAlloyRise75Wireless": "AlloyRise75/US_87_KEY.png",
    "UniversalKeyboardAlloyRise75": "AlloyRise75/US_87_KEY.png",
    "UniversalKeyboardAlloyRise": "AlloyRise/KEY_104_US.png",
    "Headset_CloudAlphaS": "HeadsetCloudAlphaSBlack.png",
    "Headset_CloudAlphaWireless": "HeadsetCloudAlphaWireless.png",
    "Headset_CloudFlight2": "CloudFlight2/CloudFlight2Black.png",
    "Headset_CloudFlightS": "HeadsetCloudFlightS.png",
    "Headset_CloudFlightWireless": "HeadsetCloudFlight.png",
    "Headset_Cloud2CoreWireless": "HeadsetCloudIICoreWireless.png",
    "Headset_Cloud2CoreWirelessTread": "HeadsetCloudIICoreWireless.png",
    "Headset_CloudIIWireless": "HeadsetCloudIIWireless.png",
    "Headset_CloudIIWirelessDTS": "HeadsetCloudIIWireless.png",
    "Headset_Cloud3SWireless": "Cloud3SWireless/Cloud3SWirelessBlack.png",
    "Headset_Cloud3Wireless": "CloudIII/Cloud3WirelessBlack.png",
    "Headset_CloudIII": "CloudIII/Cloud3WiredGray.png",
    "Headset_Ralphie": "CloudIII/Cloud3WiredGray.png",
    "Headset_CloudMix2": "CloudMIX2/CloudMIX2.png",
    "Headset_CloudMixBuds2": "CloudMIXBuds2/CloudMIXBuds2.png",
    "Headset_CloudMIXBuds": "CloudMIXBuds2/CloudMIXBuds2.png",
    "Headset_CloudStinger2Wireless": "HeadsetCloudStinger2Wireless.png",
    "Headset_StingerCoreWired": "HeadsetCloudStingerCoreWired.png",
    "Headset_StingerCoreWireless": "HeadsetCloudStingerCoreWireless.png",
    "Headset_StingerS": "HeadsetCloudStingerS.png",
    "Microphone_Duocast": "DuoCast/DuoCast.png",
    "MousePad_FURYUltra": "MousePadFURYUltra.png",
    "MousePad_PulsefireMatRGB": "MousePadFURYSRGB.png",
    "MousePulsefireCore": "MousePulsfireCore.png",
    "MousePulsefireDart": "MousePulsfireDart.png",
    "MousePulsefireFPSPro": "MousePulsfireFPSPro.png",
    "MousePulsefireFPSProCD": "MousePulsfireFPSPro.png",
    "MousePulsefireHaste": "PulsefireHaste/MousePulsfireHaste_Black.png",
    "MousePulsefireHasteWireless": "PulsefireHasteWireless/MousePulsfireHasteWirelessBlack.png",
    "MousePulsefireRaid": "MousePulsfireRaid.png",
    "MousePulsefireSurge": "MousePulsfireSurge.png",
    "UniversalMousePulsefireFuseWireless": "Universal/Mouses/PulsefireFuseWirelessBlack.png",
    "UniversalMousePulsefireHaste2": "Universal/Mouses/PulsfireHaste2Black.png",
    "UniversalMousePulsefireHaste2Wireless": "Universal/Mouses/PulsfireHaste2Black.png",
    "UniversalMousePulsefireHaste2Pro": "Universal/Mouses/PulsfireHaste2Black.png",
    "UniversalMousePulsefireHaste2MiniWireless": "Universal/Mouses/PulsfireHaste2Black.png",
    "UniversalMousePulsefireHaste2CoreWireless": "Universal/Mouses/PulsfireHaste2CoreBlack.png",
    "UniversalMousePulsefireHaste2SWireless": "Universal/Mouses/PulsefireHaste2SWirelessBlue.png",
    "UniversalMousePulsefireSaga": "Universal/Mouses/PulsfireSaga.png",
    "UniversalMousePulsefireSagaPro": "Universal/Mouses/PulsfireSagaPro.png",
    "Microphone_Quadcast2S": "QuadCast2S/Audio_Black.png",
    "Microphone_QuadCast2": "QuadCast2/QuadCast2Black.png",
    "Microphone_QuadcastS": "MicrophoneQuadCastS.png",
    "Microphone_Solocast": "SoloCast/SoloCastBlack.png",
}

src, dst = sys.argv[1], sys.argv[2]
os.makedirs(dst, exist_ok=True)
for model, rel in IMAGES.items():
    out = os.path.join(dst, model + ".png")
    subprocess.run(["sips", "-Z", "800", os.path.join(src, rel), "--out", out],
                   check=True, stdout=subprocess.DEVNULL)
    os.chmod(out, 0o644)
print(f"{len(IMAGES)} imagens em {dst}")
