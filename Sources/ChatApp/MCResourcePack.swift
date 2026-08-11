import Foundation
import UIKit
import ZIPFoundation

/// Quản lý resource pack Minecraft 1.12.x.
/// - Tự nhận pack server gửi qua Resource Pack Send.
/// - Cho phép người dùng import .zip thủ công.
/// - Giải nén và tra texture PNG từ assets/minecraft.
/// - Nếu server pack không có texture/model phù hợp, dùng asset vanilla Minecraft 1.12.2 thật.
/// - Không dùng emoji làm icon item.
@MainActor
final class MCResourcePackStore: ObservableObject {
    static let shared = MCResourcePackStore()

    @Published private(set) var activePackName: String?
    @Published private(set) var activePackURL: URL?

    // Server pack luôn được ưu tiên. Vanilla 1.12.2 là fallback để mọi item Minecraft
    // vẫn có icon thật ngay cả khi server pack chỉ chứa phần override/custom.
    private var files: [String: URL] = [:]
    private var vanillaFiles: [String: URL] = [:]
    private var imageCache: [String: UIImage] = [:]
    private var modelTextureCache: [String: String?] = [:]
    private var vanillaReady = false
    private var vanillaLoading = false

    private init() {
        if let saved = UserDefaults.standard.string(forKey: "mc_active_resource_pack"),
           FileManager.default.fileExists(atPath: saved) {
            loadExtractedPack(URL(fileURLWithPath: saved), displayName: URL(fileURLWithPath: saved).lastPathComponent)
        }
    }

    func importPack(from zipURL: URL) async throws {
        let accessed = zipURL.startAccessingSecurityScopedResource()
        defer { if accessed { zipURL.stopAccessingSecurityScopedResource() } }

        let base = try FileManager.default.url(for: .documentDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
            .appendingPathComponent("TexturePacks", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let folder = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: zipURL, to: folder)

        loadExtractedPack(folder, displayName: zipURL.deletingPathExtension().lastPathComponent)
    }

    func installDownloadedPack(zipURL: URL, name: String) throws {
        let base = try FileManager.default.url(for: .documentDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
            .appendingPathComponent("TexturePacks", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let folder = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: zipURL, to: folder)

        loadExtractedPack(folder, displayName: name)
    }

    func clearPack() {
        activePackName = nil
        activePackURL = nil
        files.removeAll()
        imageCache.removeAll()
        modelTextureCache.removeAll()
        UserDefaults.standard.removeObject(forKey: "mc_active_resource_pack")
    }

    func image(for item: MCItemSlot) -> UIImage? {
        image(for: item.itemId, damage: item.damage)
    }

    func image(for item: MCOpenWindowItem) -> UIImage? {
        image(for: item.itemId, damage: item.damage)
    }

    private func image(for itemId: Int16, damage: Int16) -> UIImage? {
        // Server pack được ưu tiên; vanilla 1.12.2 là fallback. Không dùng emoji vì
        // người dùng yêu cầu icon item Minecraft thật.

        // Ưu tiên model JSON của resource pack server. Model có parent + overrides +
        // textures được resolve đệ quy giống Minecraft client thay vì chỉ đọc layer0.
        for name in mcLegacyItemTextureNames(itemId: itemId, damage: damage) {
            if let texture = resolveItemTexture(modelName: name, itemId: itemId, damage: damage, visited: []) ,
               let image = imageForTextureReference(texture) {
                return image
            }

            if let image = imageForTextureReference("items/\(name)") ?? imageForTextureReference("blocks/\(name)") {
                return image
            }
        }

        return nil
    }

    private func resolveItemTexture(modelName: String, itemId: Int16, damage: Int16, visited: Set<String>) -> String? {
        let key = modelName.lowercased()
        guard !visited.contains(key) else { return nil }
        var visited = visited
        visited.insert(key)

        guard let modelURL = find("assets/minecraft/models/item/\(modelName).json") else { return nil }
        guard let data = try? Data(contentsOf: modelURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var textures = obj["textures"] as? [String: Any] ?? [:]

        // Overrides được chọn theo damage predicate của Minecraft 1.12.
        if let overrides = obj["overrides"] as? [[String: Any]] {
            let normalizedDamage = normalizedItemDamage(itemId: itemId, damage: damage)
            var best: (threshold: Double, model: String)?
            for override in overrides {
                guard let predicate = override["predicate"] as? [String: Any],
                      let model = override["model"] as? String else { continue }
                let threshold = (predicate["damage"] as? NSNumber)?.doubleValue ?? -1
                guard threshold >= 0, normalizedDamage >= threshold else { continue }
                if best == nil || threshold > best!.threshold {
                    best = (threshold, model)
                }
            }
            if let best {
                let normalizedModel = best.model
                    .replacingOccurrences(of: "minecraft:", with: "")
                    .replacingOccurrences(of: ".json", with: "")
                    .replacingOccurrences(of: "models/item/", with: "")
                if let texture = resolveItemTexture(modelName: normalizedModel, itemId: itemId, damage: damage, visited: visited) {
                    return texture
                }
            }
        }

        // Parent model có thể chứa texture (item/generated, item/handheld, block/*...).
        if let parent = obj["parent"] as? String {
            let parentName = parent
                .replacingOccurrences(of: "minecraft:", with: "")
                .replacingOccurrences(of: ".json", with: "")
            let pathPart = parentName
                .replacingOccurrences(of: "models/item/", with: "")
                .replacingOccurrences(of: "item/", with: "")
            if let parentTexture = resolveAnyModelTexture(modelName: pathPart, itemId: itemId, damage: damage, visited: visited, textures: &textures) {
                return parentTexture
            }
        }

        // layer0 là texture 2D chính của item.
        if let layer0 = textureValue("layer0", in: textures) { return layer0 }
        if let first = textures.values.compactMap({ $0 as? String }).first { return first }
        return nil
    }

    private func resolveAnyModelTexture(modelName: String, itemId: Int16, damage: Int16, visited: Set<String>, textures: inout [String: Any]) -> String? {
        let modelKey = modelName.lowercased()
        guard !visited.contains(modelKey) else { return nil }
        guard let url = find("assets/minecraft/models/item/\(modelName).json") ?? find("assets/minecraft/models/block/\(modelName).json") else { return nil }
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let local = obj["textures"] as? [String: Any] {
            for (k, v) in local { if textures[k] == nil { textures[k] = v } }
            if let layer0 = textureValue("layer0", in: local) { return layer0 }
            if let all = textureValue("all", in: local) { return all }
            if let side = textureValue("side", in: local) { return side }
            if let first = local.values.compactMap({ $0 as? String }).first { return first }
        }
        if let parent = obj["parent"] as? String {
            let parentName = parent.replacingOccurrences(of: "minecraft:", with: "").replacingOccurrences(of: ".json", with: "")
            return resolveAnyModelTexture(modelName: parentName, itemId: itemId, damage: damage, visited: visited, textures: &textures)
        }
        return nil
    }

    private func textureValue(_ key: String, in textures: [String: Any]) -> String? {
        guard let value = textures[key] as? String else { return nil }
        if value.hasPrefix("#") { return textures[String(value.dropFirst())] as? String }
        return value
    }

    private func imageForTextureReference(_ reference: String) -> UIImage? {
        var normalized = reference
            .replacingOccurrences(of: "minecraft:", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized.hasPrefix("#") { return nil }
        let key = normalized.hasSuffix(".png") ? normalized : normalized + ".png"

        if let cached = imageCache[key] { return cached }
        guard let url = find("assets/minecraft/textures/\(key)"),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        imageCache[key] = image
        return image
    }

    /// Tải vanilla Minecraft 1.12.2 chính thức vào sandbox lần đầu. Đây không được đóng gói
    /// trong repo; app tự tải client.jar và chỉ dùng thư mục assets để hiển thị icon.
    func ensureVanillaAssets() async {
        guard !vanillaReady, !vanillaLoading else { return }
        vanillaLoading = true
        defer { vanillaLoading = false }

        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("VanillaMinecraft-1.12.2", isDirectory: true)
            if FileManager.default.fileExists(atPath: base.appendingPathComponent("assets/minecraft/models/item").path) {
                loadVanillaIndex(base)
                return
            }
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let jarURL = base.appendingPathComponent("1.12.2.jar")
            let remote = URL(string: "https://launcher.mojang.com/v1/objects/0f275bc1547d01fa5f56ba34bdc87d981ee12daf/client.jar")!
            let (tmp, _) = try await URLSession.shared.download(from: remote)
            try? FileManager.default.removeItem(at: jarURL)
            try FileManager.default.moveItem(at: tmp, to: jarURL)
            let extracted = base.appendingPathComponent("extracted", isDirectory: true)
            if FileManager.default.fileExists(atPath: extracted.path) { try? FileManager.default.removeItem(at: extracted) }
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: jarURL, to: extracted)
            loadVanillaIndex(extracted)
        } catch {
            // Không làm app crash nếu mạng bị chặn; server pack vẫn có thể hoạt động.
            return
        }
    }


    private func normalizedItemDamage(itemId: Int16, damage: Int16) -> Double {
        guard damage > 0 else { return 0 }
        let maxDamage = mcLegacyMaxDurability(itemId: itemId)
        return min(1, max(0, Double(damage) / Double(maxDamage)))
    }

    private func buildIndex(_ folder: URL) -> [String: URL] {
        var index: [String: URL] = [:]
        if let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let relative = url.path.replacingOccurrences(of: folder.path + "/", with: "")
                    .replacingOccurrences(of: "\\", with: "/")
                    .lowercased()
                index[relative] = url
            }
        }
        var suffixIndex = index
        for (path, url) in index {
            if let range = path.range(of: "assets/minecraft/") {
                suffixIndex[String(path[range.lowerBound...])] = url
            }
        }
        return suffixIndex
    }

    private func loadExtractedPack(_ folder: URL, displayName: String) {
        files = buildIndex(folder)
        imageCache.removeAll()
        modelTextureCache.removeAll()
        activePackURL = folder
        activePackName = displayName
        UserDefaults.standard.set(folder.path, forKey: "mc_active_resource_pack")
    }

    private func loadVanillaIndex(_ folder: URL) {
        vanillaFiles = buildIndex(folder)
        vanillaReady = !vanillaFiles.isEmpty
        imageCache.removeAll()
        modelTextureCache.removeAll()
    }

    private func find(_ relative: String) -> URL? {
        let key = relative.lowercased()
        return files[key] ?? vanillaFiles[key]
    }
}

/// Tên item legacy phổ biến của Java 1.12.2.
/// Với resource pack custom, model JSON của pack sẽ quyết định texture thực tế.
/// Các ID không có trong bảng sẽ không bị mô phỏng bằng emoji; UI sẽ báo thiếu texture.
func mcLegacyItemTextureNames(itemId: Int16, damage: Int16) -> [String] {
    let map: [Int16: String] = [
        256:"iron_shovel",257:"iron_pickaxe",258:"iron_axe",259:"flint_and_steel",
        260:"apple",261:"bow",262:"arrow",263:"coal",264:"diamond",265:"iron_ingot",266:"gold_ingot",
        267:"iron_sword",268:"wooden_sword",269:"wooden_shovel",270:"wooden_pickaxe",271:"wooden_axe",
        272:"stone_sword",273:"stone_shovel",274:"stone_pickaxe",275:"stone_axe",
        276:"diamond_sword",277:"diamond_shovel",278:"diamond_pickaxe",279:"diamond_axe",
        280:"stick",281:"bowl",282:"mushroom_stew",283:"golden_sword",284:"golden_shovel",
        285:"golden_pickaxe",286:"golden_axe",287:"string",288:"feather",289:"gunpowder",
        290:"wooden_hoe",291:"stone_hoe",292:"iron_hoe",293:"diamond_hoe",294:"golden_hoe",
        295:"wheat_seeds",296:"wheat",297:"bread",298:"leather_helmet",299:"leather_chestplate",
        300:"leather_leggings",301:"leather_boots",302:"chainmail_helmet",303:"chainmail_chestplate",
        304:"chainmail_leggings",305:"chainmail_boots",306:"iron_helmet",307:"iron_chestplate",
        308:"iron_leggings",309:"iron_boots",310:"diamond_helmet",311:"diamond_chestplate",
        312:"diamond_leggings",313:"diamond_boots",314:"golden_helmet",315:"golden_chestplate",
        316:"golden_leggings",317:"golden_boots",318:"flint",319:"porkchop",320:"cooked_porkchop",
        321:"painting",322:"golden_apple",323:"sign",324:"wooden_door",325:"bucket",326:"water_bucket",
        327:"lava_bucket",328:"minecart",329:"saddle",330:"iron_door",331:"redstone",332:"snowball",
        333:"boat",334:"leather",335:"milk_bucket",336:"brick",337:"clay_ball",338:"sugar_cane",
        339:"paper",340:"book",341:"slime_ball",342:"chest_minecart",343:"furnace_minecart",
        344:"egg",345:"compass",346:"fishing_rod",347:"clock",348:"glowstone_dust",
        349:"fish",350:"cooked_fish",351:"dye",352:"bone",353:"sugar",354:"cake",
        355:"bed",356:"repeater",357:"cookie",358:"filled_map",359:"shears",360:"melon",
        361:"pumpkin_seeds",362:"melon_seeds",363:"beef",364:"cooked_beef",365:"chicken",
        366:"cooked_chicken",367:"rotten_flesh",368:"ender_pearl",369:"blaze_rod",
        370:"ghast_tear",371:"gold_nugget",372:"nether_wart",373:"potion",374:"glass_bottle",
        375:"spider_eye",376:"fermented_spider_eye",377:"blaze_powder",378:"magma_cream",
        379:"brewing_stand",380:"cauldron",381:"ender_eye",382:"speckled_melon",383:"spawn_egg",
        384:"experience_bottle",385:"fire_charge",386:"writable_book",387:"written_book",
        388:"emerald",389:"item_frame",390:"flower_pot",391:"carrot",392:"potato",393:"baked_potato",
        394:"poisonous_potato",395:"map",396:"golden_carrot",397:"skull",398:"carrot_on_a_stick",
        399:"nether_star",400:"pumpkin_pie",401:"fireworks",402:"firework_charge",403:"enchanted_book",
        404:"comparator",405:"netherbrick",406:"quartz",407:"tnt_minecart",408:"hopper_minecart",
        409:"prismarine_shard",410:"prismarine_crystals",411:"rabbit",412:"cooked_rabbit",
        413:"rabbit_stew",414:"rabbit_foot",415:"rabbit_hide",416:"armor_stand",417:"iron_horse_armor",
        418:"golden_horse_armor",419:"diamond_horse_armor",420:"lead",421:"name_tag",422:"command_block_minecart",
        423:"mutton",424:"cooked_mutton",425:"banner",426:"end_crystal",427:"spruce_door",
        428:"birch_door",429:"jungle_door",430:"acacia_door",431:"dark_oak_door",
        432:"chorus_fruit",433:"chorus_fruit_popped",434:"beetroot",435:"beetroot_seeds",
        436:"beetroot_soup",437:"dragon_breath",438:"splash_potion",439:"spectral_arrow",
        440:"tipped_arrow",441:"lingering_potion",442:"shield",443:"elytra",444:"spruce_boat",
        445:"birch_boat",446:"jungle_boat",447:"acacia_boat",448:"dark_oak_boat",
        449:"totem_of_undying",450:"shulker_shell",452:"iron_nugget"
    ]
    if let name = map[itemId] { return [name] }

    // Block-items: many 1.12 block IDs use the same basename under textures/blocks.
    let blockNames: [Int16:String] = [
        1:"stone",2:"grass",3:"dirt",4:"cobblestone",5:"planks",6:"sapling",7:"bedrock",
        8:"water",9:"water",10:"lava",11:"lava",12:"sand",13:"gravel",14:"gold_ore",15:"iron_ore",16:"coal_ore",
        17:"log",18:"leaves",19:"sponge",20:"glass",21:"lapis_ore",22:"lapis_block",23:"dispenser",24:"sandstone",
        25:"noteblock",26:"bed",27:"golden_rail",28:"detector_rail",29:"sticky_piston",30:"web",31:"tallgrass",32:"deadbush",
        33:"piston",34:"piston_head",35:"wool",36:"piston_extension",37:"yellow_flower",38:"red_flower",39:"brown_mushroom",40:"red_mushroom",
        41:"gold_block",42:"iron_block",43:"double_stone_slab",44:"stone_slab",45:"brick_block",46:"tnt",47:"bookshelf",48:"mossy_cobblestone",
        49:"obsidian",50:"torch",51:"fire",52:"mob_spawner",53:"oak_stairs",54:"chest",55:"redstone_wire",56:"diamond_ore",57:"diamond_block",
        58:"crafting_table",59:"wheat",60:"farmland",61:"furnace",62:"lit_furnace",63:"standing_sign",64:"wooden_door",65:"ladder",66:"rail",
        67:"stone_stairs",68:"wall_sign",69:"lever",70:"stone_pressure_plate",71:"iron_door",72:"wooden_pressure_plate",73:"redstone_ore",74:"lit_redstone_ore",
        75:"unlit_redstone_torch",76:"redstone_torch",77:"stone_button",78:"snow_layer",79:"ice",80:"snow",81:"cactus",82:"clay",
        83:"reeds",84:"jukebox",85:"fence",86:"pumpkin",87:"netherrack",88:"soul_sand",89:"glowstone",90:"portal",91:"lit_pumpkin",
        92:"cake",93:"unpowered_repeater",94:"powered_repeater",95:"stained_glass",96:"trapdoor",97:"monster_egg",98:"stonebrick",99:"brown_mushroom_block",
        100:"red_mushroom_block",101:"iron_bars",102:"glass_pane",103:"melon_block",104:"pumpkin_stem",105:"melon_stem",106:"vine",107:"fence_gate",
        108:"brick_stairs",109:"stone_brick_stairs",110:"mycelium",111:"waterlily",112:"nether_brick",113:"nether_brick_fence",114:"nether_brick_stairs",
        115:"nether_wart",116:"enchanting_table",117:"brewing_stand",118:"cauldron",119:"end_portal",120:"end_portal_frame",121:"end_stone",122:"dragon_egg",
        123:"redstone_lamp",124:"lit_redstone_lamp",125:"double_wooden_slab",126:"wooden_slab",127:"cocoa",128:"sandstone_stairs",129:"emerald_ore",
        130:"ender_chest",131:"tripwire_hook",132:"tripwire",133:"emerald_block",134:"spruce_stairs",135:"birch_stairs",136:"jungle_stairs",137:"command_block",
        138:"beacon",139:"cobblestone_wall",140:"flower_pot",141:"carrots",142:"potatoes",143:"wooden_button",144:"skull",145:"anvil",146:"trapped_chest",
        147:"light_weighted_pressure_plate",148:"heavy_weighted_pressure_plate",149:"unpowered_comparator",150:"powered_comparator",151:"daylight_detector",152:"redstone_block",
        153:"quartz_ore",154:"hopper",155:"quartz_block",156:"quartz_stairs",157:"activator_rail",158:"dropper",159:"stained_hardened_clay",160:"stained_glass_pane",
        161:"leaves2",162:"log2",163:"acacia_stairs",164:"dark_oak_stairs",165:"slime",166:"barrier",167:"iron_trapdoor",168:"prismarine",
        169:"sea_lantern",170:"hay_block",171:"carpet",172:"hardened_clay",173:"coal_block",174:"packed_ice",175:"double_plant",
    ]
    if let name = blockNames[itemId] { return [name] }
    return []
}

private func mcLegacyMaxDurability(itemId: Int16) -> Int {
    switch itemId {
    case 256, 257, 258, 267: return 250
    case 269, 270, 271, 268: return 59
    case 272, 273, 274, 275: return 131
    case 276, 277, 278, 279: return 1561
    case 283, 284, 285, 286: return 32
    case 290: return 59
    case 291: return 131
    case 292: return 250
    case 293: return 1561
    case 294: return 32
    case 298, 299, 300, 301: return 55
    case 302, 303, 304, 305: return 165
    case 306, 307, 308, 309: return 165
    case 310, 311, 312, 313: return 363
    case 314, 315, 316, 317: return 77
    case 261: return 384
    case 346, 442: return 64
    case 359: return 238
    default: return 32767
    }
}
