#!/usr/bin/env swift
//
//  K70HardwareProfileBurner.swift
//  Tools
//
//  Permanently burns 3 standalone hardware profiles into the onboard SPI NOR Flash
//  of the Corsair K70 RGB MK.2 Mechanical Gaming Keyboard (VID: 0x1B1C, PID: 0x1B49).
//

import Foundation
import IOKit
import IOKit.hid

setbuf(stdout, nil)

print("============================================================")
print("  CORSAIR K70 RGB MK.2 - 3 ONBOARD HARDWARE PROFILE BURNER  ")
print("============================================================")

struct ProfileConfig {
    let slot: Int
    let name: String
    let r: UInt8
    let g: UInt8
    let b: UInt8
}

// Target Profiles & Exact Color Specifications:
// 1. Slot 1: Pure Carmine Red (255, 0, 0 / #FF0000)
// 2. Slot 2: Night Vision Green (70, 255, 0 / #46FF00)
// 3. Slot 3: Glacier Ice Cyan (154, 220, 231 / #9ADCE7)
let targetProfiles: [ProfileConfig] = [
    ProfileConfig(slot: 0, name: "Profile 1", r: 255, g: 0,   b: 0),
    ProfileConfig(slot: 1, name: "Profile 2", r: 70,  g: 255, b: 0),
    ProfileConfig(slot: 2, name: "Profile 3", r: 154, g: 220, b: 231)
]

func burnAllProfiles(dev: IOHIDDevice) {
    print("\n▶ Klavyenin dahili mikroçipiyle iletişim başlatılıyor...")

    func sendReport(_ bytes: [UInt8]) -> Bool {
        var pkt = [UInt8](repeating: 0, count: 64)
        for (i, b) in bytes.enumerated() where i < 64 { pkt[i] = b }
        let kr = IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 0, pkt, 64)
        return kr == 0
    }

    func getOpStatus() -> (st: UInt8, err: UInt8) {
        let krSet = sendReport([0x0E, 0x17, 0x0D, 0x00])
        if !krSet {
            return (0xFE, 0xFE)
        }
        usleep(15000) // 15ms settle time for MCU USB FIFO
        var resp = [UInt8](repeating: 0, count: 64)
        var len = 64
        let kr = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 0, &resp, &len)
        if kr == 0 {
            return (resp[4], resp[5])
        }
        return (0xFE, 0xFE)
    }

    func waitOp(timeoutMs: Int = 4000, desc: String = "") -> (st: UInt8, err: UInt8) {
        usleep(40000) // 40ms initial settle time
        let start = Date()
        while Date().timeIntervalSince(start) * 1000.0 < Double(timeoutMs) {
            let (st, err) = getOpStatus()
            // 0x01 = InProgress, 0xFE = USB bus settling / SPI flash busy
            if st != 0x01 && st != 0xFE {
                return (st, err)
            }
            usleep(40000) // 40ms polling interval
        }
        print("  ⚠️ Timeout waiting for: \(desc)")
        return (0xFE, 0xFE)
    }

    func closeFile() {
        _ = sendReport([0x07, 0x17, 0x08, 0x00])
        _ = waitOp(timeoutMs: 3000, desc: "closeFile")
        usleep(30000)
    }

    func openFileForWrite(name: String, timeoutMs: Int = 8000) -> Bool {
        var openPkt = [UInt8](repeating: 0, count: 64)
        openPkt[0] = 0x07; openPkt[1] = 0x17; openPkt[2] = 0x05; openPkt[3] = 0x00
        let nameBytes = Array(name.utf8)
        for i in 0..<nameBytes.count { openPkt[4 + i] = nameBytes[i] }

        let start = Date()
        while Date().timeIntervalSince(start) * 1000.0 < Double(timeoutMs) {
            let ok = sendReport(openPkt)
            if !ok {
                usleep(200000)
                continue
            }
            let res = waitOp(timeoutMs: 3500, desc: "openWrite \(name)")
            if res.st == 0x00 || res.st == 0x04 {
                return true
            }
            if res.st == 0x03 { // FileAlreadyOpened -> close and retry
                closeFile()
            } else if res.st == 0x0C || res.st == 0x0D { // Flash busy
                usleep(500000) // Wait 500ms for flash erase/write cycle
            } else {
                usleep(200000)
            }
        }
        print("  ❌ Failed to open \(name) for write after timeout")
        return false
    }

    func writeFile(name: String, data: [UInt8]) -> Bool {
        guard openFileForWrite(name: name) else {
            return false
        }
        var offset = 0
        while offset < data.count {
            let batchLen = min(300, data.count - offset)
            let batch = Array(data[offset..<(offset + batchLen)])
            let pkts = (batchLen + 59) / 60
            for p in 1...pkts {
                let s = (p - 1) * 60
                let e = min(s + 60, batchLen)
                let chunk = Array(batch[s..<e])
                var pkt = [UInt8](repeating: 0, count: 64)
                pkt[0] = 0x7F; pkt[1] = UInt8(p); pkt[2] = UInt8(chunk.count); pkt[3] = 0x00
                for i in 0..<chunk.count { pkt[4 + i] = chunk[i] }
                let ok = sendReport(pkt)
                if !ok {
                    closeFile()
                    return false
                }
                usleep(12000) // 12ms quiet delay between chunk packets
            }
            // Flush batch to MCU buffer: 0x09 commits the 300-byte SRAM buffer into file stream
            let okFlush = sendReport([0x07, 0x17, 0x09, 0x00])
            if !okFlush {
                closeFile()
                return false
            }
            usleep(25000) // 25ms settle time for SRAM commit
            offset += batchLen
        }
        closeFile()
        // If this was the large RGB buffer (lght_00.r), give SPI Flash 800ms to commit the 1024 bytes
        if data.count >= 500 {
            usleep(800000) // 800ms settle for SPI Flash
        } else {
            usleep(50000)  // 50ms settle for small files
        }
        return true
    }

    // 1. Enter Software Mode to grant access to MCU SPI flash operations
    print("▶ Entering Software Mode...")
    let ok1 = sendReport([0x07, 0x04, 0x02, 0x00])
    let ok2 = sendReport([0x07, 0x05, 0x02, 0x00, 0x03])
    if !ok1 || !ok2 {
        print("❌ HATA: Klavye yazılım moduna geçirilemedi! USB hattı kilitli.")
        exit(1)
    }
    usleep(50000)

    for p in targetProfiles {
        let slotNum = p.slot + 1
        print("\n------------------------------------------------------------")
        print("▶ Programming Slot \(slotNum) of 3: \(p.name) (R:\(p.r), G:\(p.g), B:\(p.b))...")
        print("------------------------------------------------------------")

        // Step A: Register Profile Info (Command 0x15)
        let guid: [UInt8] = [
            0xC0, 0x85, 0xA1, 0x01,
            0x4A, 0x70, 0x4B, 0x70,
            0x80, UInt8(slotNum), 0x00, 0x00,
            0x00, 0x00, 0x00, UInt8(slotNum)
        ]
        let hwId: [UInt8] = [UInt8(slotNum), 0x00, 0x00]

        var infoPkt = [UInt8](repeating: 0, count: 64)
        infoPkt[0] = 0x07; infoPkt[1] = 0x15; infoPkt[2] = UInt8(p.slot); infoPkt[3] = 0x00
        for i in 0..<16 { infoPkt[4 + i] = guid[i] }
        infoPkt[20] = hwId[0]; infoPkt[21] = hwId[1]; infoPkt[22] = hwId[2]; infoPkt[23] = 0x01

        var infoRegistered = false
        for attempt in 1...5 {
            let ok = sendReport(infoPkt)
            if !ok { break }
            let infoSt = waitOp(timeoutMs: 3000, desc: "commitProfileInfo \(slotNum)")
            if infoSt.st == 0x00 {
                infoRegistered = true
                print("  ✓ Profile info registered (st=0)")
                break
            } else if infoSt.st == 0x0C || infoSt.st == 0x0D {
                print("  ⏳ SPI Flash meşgul (st=\(infoSt.st)), bekleniyor (deneme \(attempt)/5)...")
                sleep(2)
            } else {
                usleep(200000)
            }
        }
        if !infoRegistered {
            print("  ❌ KRİTİK HATA: Slot \(slotNum) profil bilgisi kaydedilemedi! İşlem iptal ediliyor.")
            exit(1)
        }

        // Step B: Set Current Profile Slot Directory (FileOperation 0x0C)
        let okSlot = sendReport([0x07, 0x17, 0x0C, UInt8(p.slot)])
        if !okSlot {
            print("  ❌ KRİTİK HATA: Slot \(slotNum) dizini seçilemedi!")
            exit(1)
        }
        usleep(150000) // 150ms settle for slot directory pointer
        print("  ✓ Selected slot directory (Slot \(slotNum))")

        // Step C: Build 7 Profile Files
        // 1. PROFILE.DAT (4 bytes): Windows Lock Key action = DISABLED (0x00)
        let profileDat: [UInt8] = [0x50, 0x00, 0x00, 0x00]

        // 2. PROFILE.I (268 bytes): Metadata & Top Buttons color
        var profileI = [UInt8](repeating: 0, count: 268)
        profileI[0] = 0x49; profileI[1] = 0x00
        for i in 0..<16 { profileI[2 + i] = guid[i] }
        profileI[18] = hwId[0]; profileI[19] = hwId[1]; profileI[20] = hwId[2]; profileI[21] = 0x00
        if let nameData = p.name.data(using: .utf16LittleEndian) {
            nameData.copyBytes(to: &profileI[22], count: min(nameData.count, 230))
        }
        profileI[252] = 0x00
        profileI[253] = p.r; profileI[254] = p.g; profileI[255] = p.b // Profile Button RGB
        profileI[256] = p.r; profileI[257] = p.g; profileI[258] = p.b // Brightness Button RGB
        profileI[259] = p.r; profileI[260] = p.g; profileI[261] = p.b // WinLock Locked RGB
        profileI[262] = p.r; profileI[263] = p.g; profileI[264] = p.b // WinLock Unlocked RGB
        profileI[265] = 0xFF // SidelightingControl enabled

        // 3. PROFILE.MAP (4 bytes)
        let profileMap: [UInt8] = [0x41, 0x00, 0x00, 0x00]

        // 4. lght_00.d (37 bytes): Static lighting mode
        var lghtD = [UInt8](repeating: 0, count: 37)
        lghtD[0] = 0x07
        lghtD[18] = 0x01

        // 5. lght_00.k (160 bytes): Key mapping table (156 keys)
        var lghtK = [UInt8](repeating: 0, count: 160)
        lghtK[0] = 0x9C
        for k in 0..<156 { lghtK[4 + k] = UInt8(k) }

        // 6. lght_00.r (1024 bytes): RGB color values for all 156 keys
        var lghtR = [UInt8](repeating: 0, count: 1024)
        for k in 0..<156 {
            let base = k * 4
            lghtR[base]     = p.r
            lghtR[base + 1] = p.g
            lghtR[base + 2] = p.b
            lghtR[base + 3] = 0xFF
        }

        // 7. lghtcnt.cnt (4 bytes): Lighting effect count = 1
        let lghtCnt: [UInt8] = [0x01, 0x00, 0x00, 0x00]

        let files: [(String, [UInt8])] = [
            ("PROFILE.DAT", profileDat),
            ("PROFILE.I", profileI),
            ("PROFILE.MAP", profileMap),
            ("lght_00.d", lghtD),
            ("lght_00.k", lghtK),
            ("lght_00.r", lghtR),
            ("lghtcnt.cnt", lghtCnt)
        ]

        for (fname, bytes) in files {
            let ok = writeFile(name: fname, data: bytes)
            if !ok {
                print("  ❌ KRİTİK HATA: \(fname) yazılamadı! İşlem iptal ediliyor.")
                exit(1)
            }
            print("  ✓ Wrote \(fname) (\(bytes.count) bytes)")
        }

        // Step D: Commit Profile Changes to physical SPI NOR Flash (0x0E)
        let okCommit = sendReport([0x07, 0x17, 0x0E, 0x00])
        if !okCommit {
            print("  ❌ KRİTİK HATA: Slot \(slotNum) SPI Flash'a commit edilemedi!")
            exit(1)
        }
        print("  ✓ Slot \(slotNum) committed to SPI Flash!")
        print("  ⏳ SPI Flash sektör yazım ve temizleme beklemesi (5.0 sn)...")
        sleep(5)
    }

    // Set active profile to Slot 1
    print("\n▶ Setting active slot to Profile 1...")
    _ = sendReport([0x07, 0x17, 0x0C, 0x00])
    usleep(100000)
    _ = sendReport([0x07, 0x17, 0x0E, 0x00])
    sleep(2)

    // Disable WinLock physical key action (0x00 = disabled)
    print("▶ Disabling physical Windows Lock Key action...")
    _ = sendReport([0x07, 0x48, 0x00, 0x00])
    usleep(50000)

    // Return keyboard to standalone Hardware Mode
    print("▶ Returning keyboard to standalone Hardware Mode...")
    _ = sendReport([0x07, 0x04, 0x01, 0x00])
    _ = sendReport([0x07, 0x05, 0x01, 0x00, 0x03])
    usleep(50000)

    print("\n============================================================")
    print("🎉 TEBRİKLER! 3 Donanımsal Profil Başarıyla Flash Belleğe Kazındı!")
    print("   - Profil 1: R:\(targetProfiles[0].r), G:\(targetProfiles[0].g), B:\(targetProfiles[0].b) [Aktif]")
    print("   - Profil 2: R:\(targetProfiles[1].r), G:\(targetProfiles[1].g), B:\(targetProfiles[1].b)")
    print("   - Profil 3: R:\(targetProfiles[2].r), G:\(targetProfiles[2].g), B:\(targetProfiles[2].b)")
    print("   - WinLock Tuşu: Kilit işlevi devre dışı (LED rengi profile kilitli)")
    print("   - Klavyenin sol üstündeki Profil Tuşuna basarak profiller arasında geçiş yapabilirsiniz!")
    print("============================================================\n")
    exit(0)
}

var deviceWasUnplugged = false
var hasBurned = false

let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
let match: [String: Any] = [
    kIOHIDVendorIDKey: 0x1B1C,
    kIOHIDProductIDKey: 0x1B49,
    kIOHIDPrimaryUsagePageKey: 0xFFC2,
    kIOHIDPrimaryUsageKey: 0x0004
]
IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
_ = IOHIDManagerOpen(manager, 0)

// Quick probe: Check if keyboard is already connected and responsive
if let devs = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let dev = devs.first {
    var pkt = [UInt8](repeating: 0, count: 64)
    pkt[0] = 0x07; pkt[1] = 0x04; pkt[2] = 0x02; pkt[3] = 0x00
    let kr = IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 0, pkt, 64)
    if kr == 0 {
        hasBurned = true
        burnAllProfiles(dev: dev)
    }
}

if !hasBurned {
    print("\n⚠️ Klavyenin USB iletişim hattı kilitli durumda.")
    print("👉 Lütfen K70'in kablosunu (üzerinde klavye ⌨️ simgesi olan ana USB fişini)")
    print("   çıkarıp 2 saniye sonra tekrar takın.")
    print("⏳ Program şu an dinlemede bekliyor, kablo takıldığı an OTOMATİK olarak yazmaya başlayacaktır...\n")

    IOHIDManagerRegisterDeviceRemovalCallback(manager, { _, _, _, _ in
        print("🔌 Klavye kablosu çıkarıldı (Güç kesildi). Lütfen şimdi tekrar takın...")
        deviceWasUnplugged = true
    }, nil)

    IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, device in
        guard deviceWasUnplugged && !hasBurned else { return }
        hasBurned = true
        print("🔌 Klavye USB bağlantısı algılandı! (0xFFC2:0x0004)")
        print("⏳ USB hattının oturması için 2.5 sn bekleniyor...")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) {
            burnAllProfiles(dev: device)
        }
    }, nil)

    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    CFRunLoopRun()
}
