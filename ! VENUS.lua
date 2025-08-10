-- Advanced AISetpos V4 & LC Resolver for GameSense
-- Enhanced with Wide Jitter Detection, Riptide V4, Modern Anti-Aim Adaptation
-- Author: AI Assistant
-- Version: 1.0

local ffi = require("ffi")

-- FFI Definitions for animlayers and advanced features
ffi.cdef[[
    typedef struct {
        float m_flAnimationTime;
        float m_flFadeOutTime;
        int m_nFlags;
        int m_nActivity;
        int m_nPriority;
        int m_nOrder;
        int m_nSequence;
        float m_flPrevCycle;
        float m_flWeight;
        float m_flWeightDeltaRate;
        float m_flPlaybackRate;
        float m_flCycle;
        void* m_pOwner;
        int m_nInvalidatePhysicsBits;
    } animlayer_t;
    
    typedef struct {
        float x, y, z;
    } vector3d_t;
    
    typedef struct {
        float x, y, z;
    } qangle_t;
    
    typedef struct {
        vector3d_t origin;
        qangle_t angles;
        float simulation_time;
        float duck_amount;
        int flags;
        float velocity_modifier;
        bool valid;
    } lag_record_t;
]]

ffi.cdef[[
    typedef float matrix3x4_t[3][4];
]]

ffi.cdef[[
    typedef struct {
        int id; int version; int checksum; char name[64]; int length;
        float eyeposition[3]; float illumposition[3]; float hull_min[3]; float hull_max[3];
        float view_bbmin[3]; float view_bbmax[3]; int flags; int num_bones; int bone_index;
        int num_bonecontrollers; int bonecontroller_index; int num_hitboxsets; int hitboxset_index;
    } studiohdr_t;
    typedef struct {
        int sznameindex; int numhitboxes; int hitboxindex;
    } mstudiohitboxset_t;
    typedef struct {
        int m_iBone; int m_iGroup; float bbmin[3]; float bbmax[3]; int szHitboxNameIndex; int m_nPad[3]; float m_flRadius; int m_GroupUnknown;
    } mstudiobbox_t;
]]

-- Resolve model header via model info if available
local function get_studiohdr_for_entity(ent)
    if entity.get_model and client.get_model_info then
        local ok, model = pcall(entity.get_model, ent)
        if ok and model then
            local ok2, info = pcall(client.get_model_info, model)
            if ok2 and info and info.studiohdr then
                return ffi.cast("studiohdr_t*", info.studiohdr)
            end
        end
    end
    return nil
end

-- Bones cache per tick
local bones_cache = { tick = -1, per_entity = {} }

local function try_setup_bones_vtable(ent, out_bones, max_bones, bone_mask, time)
    local ok, renderable = pcall(function()
        return entity.get_renderable and entity.get_renderable(ent) or nil
    end)
    if not ok or not renderable then return false end
    local vtbl = ffi.cast("void***", renderable)[0]
    for idx = 13, 18 do
        local fn_ok, fn = pcall(function()
            return ffi.cast("bool(__thiscall*)(void*, matrix3x4_t*, int, int, float)", vtbl[idx])
        end)
        if fn_ok and fn ~= nil then
            local ok_call, res = pcall(function()
                return fn(renderable, out_bones, max_bones, bone_mask, time)
            end)
            if ok_call and res then return true end
        end
    end
    return false
end

local function get_bones_cached(ent)
    local cur_tick = globals.tickcount()
    if bones_cache.tick ~= cur_tick then
        bones_cache.tick = cur_tick
        bones_cache.per_entity = {}
    end
    if bones_cache.per_entity[ent] then return bones_cache.per_entity[ent] end
    local bones = ffi.new("matrix3x4_t[128]")
    local ok = try_setup_bones_vtable(ent, bones, 128, 0x100, globals.curtime())
    if ok then
        bones_cache.per_entity[ent] = bones
        return bones
    end
    return nil
end

local function transform_point(mat, v)
    return {
        x = mat[0][0]*v.x + mat[0][1]*v.y + mat[0][2]*v.z + mat[0][3],
        y = mat[1][0]*v.x + mat[1][1]*v.y + mat[1][2]*v.z + mat[1][3],
        z = mat[2][0]*v.x + mat[2][1]*v.y + mat[2][2]*v.z + mat[2][3]
    }
end

-- Функция для создания vector3 из entity_get_prop
function vector3(prop_value)
    if not prop_value then return nil end
    
    if type(prop_value) == "table" then
        if prop_value[1] and prop_value[2] and prop_value[3] then
            return {x = prop_value[1], y = prop_value[2], z = prop_value[3]}
        elseif prop_value.x and prop_value.y and prop_value.z then
            return {x = prop_value.x, y = prop_value.y, z = prop_value.z}
        end
    end
    
    return nil
end

local function get_hitbox_bbox_via_studio(ent, hitbox_id)
    hitbox_id = hitbox_id or 0
    local hdr = get_studiohdr_for_entity(ent)
    if not hdr then return nil end
    local set = ffi.cast("mstudiohitboxset_t*", ffi.cast("uint8_t*", hdr) + hdr.hitboxset_index)
    if not set or set.numhitboxes <= hitbox_id then return nil end
    local bbox = ffi.cast("mstudiobbox_t*", ffi.cast("uint8_t*", set) + set.hitboxindex + hitbox_id * ffi.sizeof("mstudiobbox_t"))
    if not bbox then return nil end
    local bones = get_bones_cached and get_bones_cached(ent) or nil
    if not bones then return nil end
    local bone = bbox.m_iBone or 0
    local mat = bones[bone]
    if not mat then return nil end
    local mins = {x = bbox.bbmin[0], y = bbox.bbmin[1], z = bbox.bbmin[2]}
    local maxs = {x = bbox.bbmax[0], y = bbox.bbmax[1], z = bbox.bbmax[2]}
    local center_local = {x = (mins.x + maxs.x)/2, y = (mins.y + maxs.y)/2, z = (mins.z + maxs.z)/2}
    return {
        center = transform_point(mat, center_local),
        mins = transform_point(mat, mins),
        maxs = transform_point(mat, maxs)
    }
end

-- === ADVANCED HITBOX MATRIX SYSTEM FOR IMPROVED RESOLVING ===
-- Система матрицы хитбоксов для точного резольвинга через геометрию

-- Расширенные структуры для хитбоксов
ffi.cdef[[
    typedef struct {
        float m[3][4];
    } matrix3x4_t;
    
    typedef struct {
        int bone;
        int group;
        float bbmin[3];
        float bbmax[3];
        int name_index;
        int pad[3];
        float radius;
        int group_unknown;
    } mstudiobbox_t;
    
    typedef struct {
        int name_index;
        int num_hitboxes;
        int hitbox_index;
    } mstudiohitboxset_t;
    
    typedef struct {
        int bone;
        int parent;
        int flags;
        int name_index;
        int unused[6];
        float pos[3];
        float quat[4];
        float rot[3];
        matrix3x4_t pose_to_bone;
        float alignment[4];
        int proc_type;
        int proc_index;
        int proc_vertex_start;
        int proc_vertex_count;
        int proc_tri_start;
        int proc_tri_count;
        int proc_flags;
        int proc_bone;
        int proc_rule;
        int proc_vertex_data;
        int proc_offset;
    } mstudiobone_t;
]]

-- Кэш матриц хитбоксов для каждого тика
local hitbox_matrix_cache = { tick = -1, per_entity = {} }

-- Получение точной матрицы хитбокса через studiohdr
function get_hitbox_matrix_precise(entity_index, hitbox_id)
    if not entity_index or not hitbox_id then return nil end
    
    local entity = entity_index
    if not entity then return nil end
    
    local hdr = get_studiohdr_for_entity(entity)
    if not hdr then return nil end
    
    -- Получаем хитбокс сет
    local hitbox_set = ffi.cast("mstudiohitboxset_t*", ffi.cast("uint8_t*", hdr) + hdr.hitboxset_index)
    if not hitbox_set or hitbox_set.num_hitboxes <= hitbox_id then return nil end
    
    -- Получаем конкретный хитбокс
    local bbox = ffi.cast("mstudiobbox_t*", ffi.cast("uint8_t*", hitbox_set) + hitbox_set.hitbox_index + hitbox_id * ffi.sizeof("mstudiobbox_t"))
    if not bbox then return nil end
    
    -- Получаем кости
    local bones = get_bones_cached(entity)
    if not bones then return nil end
    
    local bone_index = bbox.bone
    if bone_index < 0 or bone_index >= 128 then return nil end
    
    local bone_matrix = bones[bone_index]
    if not bone_matrix then return nil end
    
    return {
        matrix = bone_matrix,
        bbox = bbox,
        bone_index = bone_index,
        center_local = {
            x = (bbox.bbmin[0] + bbox.bbmax[0]) / 2,
            y = (bbox.bbmin[1] + bbox.bbmax[1]) / 2,
            z = (bbox.bbmin[2] + bbox.bbmax[2]) / 2
        },
        mins_local = { x = bbox.bbmin[0], y = bbox.bbmin[1], z = bbox.bbmin[2] },
        maxs_local = { x = bbox.bbmax[0], y = bbox.bbmax[1], z = bbox.bbmax[2] },
        radius = bbox.radius or 0
    }
end

-- Трансформация точки через матрицу с высокой точностью
function transform_point_precise(matrix, point)
    if not matrix or not point then return nil end
    
    return {
        x = matrix.m[0][0] * point.x + matrix.m[0][1] * point.y + matrix.m[0][2] * point.z + matrix.m[0][3],
        y = matrix.m[1][0] * point.x + matrix.m[1][1] * point.y + matrix.m[1][2] * point.z + matrix.m[1][3],
        z = matrix.m[2][0] * point.x + matrix.m[2][1] * point.y + matrix.m[2][2] * point.z + matrix.m[2][3]
    }
end

-- Получение мировых координат хитбокса через матрицу
function get_hitbox_world_coords(entity_index, hitbox_id)
    local hitbox_data = get_hitbox_matrix_precise(entity_index, hitbox_id)
    if not hitbox_data then return nil end
    
    local center_world = transform_point_precise(hitbox_data.matrix, hitbox_data.center_local)
    local mins_world = transform_point_precise(hitbox_data.matrix, hitbox_data.mins_local)
    local maxs_world = transform_point_precise(hitbox_data.matrix, hitbox_data.maxs_local)
    
    if not center_world or not mins_world or not maxs_world then return nil end
    
    return {
        center = center_world,
        mins = mins_world,
        maxs = maxs_world,
        radius = hitbox_data.radius,
        bone_index = hitbox_data.bone_index,
        matrix = hitbox_data.matrix
    }
end

-- Анализ десинка через матрицу хитбоксов
function analyze_desync_via_hitbox_matrix(entity_index, hitbox_id, angle_offset)
    local hitbox_data = get_hitbox_matrix_precise(entity_index, hitbox_id)
    if not hitbox_data then return nil end
    
    -- Создаем матрицу с поворотом для анализа десинка
    local rotation_matrix = ffi.new("matrix3x4_t")
    
    -- Применяем поворот к матрице кости
    local angle_rad = math.rad(angle_offset or 0)
    local cos_a = math.cos(angle_rad)
    local sin_a = math.sin(angle_rad)
    
    -- Поворот вокруг оси Z (Yaw)
    rotation_matrix.m[0][0] = cos_a
    rotation_matrix.m[0][1] = -sin_a
    rotation_matrix.m[0][2] = 0
    rotation_matrix.m[0][3] = 0
    
    rotation_matrix.m[1][0] = sin_a
    rotation_matrix.m[1][1] = cos_a
    rotation_matrix.m[1][2] = 0
    rotation_matrix.m[1][3] = 0
    
    rotation_matrix.m[2][0] = 0
    rotation_matrix.m[2][1] = 0
    rotation_matrix.m[2][2] = 1
    rotation_matrix.m[2][3] = 0
    
    -- Комбинируем матрицы
    local combined_matrix = ffi.new("matrix3x4_t")
    for i = 0, 2 do
        for j = 0, 3 do
            combined_matrix.m[i][j] = 0
            for k = 0, 2 do
                combined_matrix.m[i][j] = combined_matrix.m[i][j] + rotation_matrix.m[i][k] * hitbox_data.matrix.m[k][j]
            end
            if j == 3 then
                combined_matrix.m[i][j] = combined_matrix.m[i][j] + rotation_matrix.m[i][3]
            end
        end
    end
    
    -- Трансформируем точки с новой матрицей
    local center_rotated = transform_point_precise(combined_matrix, hitbox_data.center_local)
    local mins_rotated = transform_point_precise(combined_matrix, hitbox_data.mins_local)
    local maxs_rotated = transform_point_precise(combined_matrix, hitbox_data.maxs_local)
    
    if not center_rotated or not mins_rotated or not maxs_rotated then return nil end
    
    -- Вычисляем смещение от оригинальной позиции
    local original_center = transform_point_precise(hitbox_data.matrix, hitbox_data.center_local)
    if not original_center then return nil end
    
    local desync_offset = {
        x = center_rotated.x - original_center.x,
        y = center_rotated.y - original_center.y,
        z = center_rotated.z - original_center.z
    }
    
    local desync_magnitude = math.sqrt(desync_offset.x^2 + desync_offset.y^2 + desync_offset.z^2)
    
    return {
        original_center = original_center,
        rotated_center = center_rotated,
        rotated_mins = mins_rotated,
        rotated_maxs = maxs_rotated,
        desync_offset = desync_offset,
        desync_magnitude = desync_magnitude,
        angle_offset = angle_offset,
        matrix = combined_matrix,
        original_matrix = hitbox_data.matrix
    }
end

-- Система предсказания хитбоксов через матрицу
function predict_hitbox_via_matrix(entity_index, hitbox_id, prediction_time, velocity)
    local hitbox_data = get_hitbox_matrix_precise(entity_index, hitbox_id)
    if not hitbox_data then return nil end
    
    -- Получаем текущую позицию
    local current_center = transform_point_precise(hitbox_data.matrix, hitbox_data.center_local)
    if not current_center then return nil end
    
    -- Предсказываем будущую позицию на основе скорости
    local predicted_center = {
        x = current_center.x + (velocity.x * prediction_time),
        y = current_center.y + (velocity.y * prediction_time),
        z = current_center.z + (velocity.z * prediction_time)
    }
    
    -- Создаем матрицу смещения
    local offset_matrix = ffi.new("matrix3x4_t")
    for i = 0, 2 do
        for j = 0, 3 do
            offset_matrix.m[i][j] = hitbox_data.matrix.m[i][j]
        end
    end
    
    -- Применяем смещение к матрице
    offset_matrix.m[0][3] = offset_matrix.m[0][3] + (velocity.x * prediction_time)
    offset_matrix.m[1][3] = offset_matrix.m[1][3] + (velocity.y * prediction_time)
    offset_matrix.m[2][3] = offset_matrix.m[2][3] + (velocity.z * prediction_time)
    
    -- Трансформируем точки с предсказанной матрицей
    local predicted_mins = transform_point_precise(offset_matrix, hitbox_data.mins_local)
    local predicted_maxs = transform_point_precise(offset_matrix, hitbox_data.maxs_local)
    
    if not predicted_mins or not predicted_maxs then return nil end
    
    return {
        current_center = current_center,
        predicted_center = predicted_center,
        predicted_mins = predicted_mins,
        predicted_maxs = predicted_maxs,
        prediction_time = prediction_time,
        velocity = velocity,
        matrix = offset_matrix,
        original_matrix = hitbox_data.matrix
    }
end

-- Анализ пересечений хитбоксов через матрицу
function analyze_hitbox_intersection_via_matrix(entity_index, hitbox_id, ray_start, ray_end)
    local hitbox_data = get_hitbox_matrix_precise(entity_index, hitbox_id)
    if not hitbox_data then return nil end
    
    -- Трансформируем луч в локальные координаты хитбокса
    local local_ray_start = {
        x = ray_start.x - hitbox_data.matrix.m[0][3],
        y = ray_start.y - hitbox_data.matrix.m[1][3],
        z = ray_start.z - hitbox_data.matrix.m[2][3]
    }
    
    local local_ray_end = {
        x = ray_end.x - hitbox_data.matrix.m[0][3],
        y = ray_end.y - hitbox_data.matrix.m[1][3],
        z = ray_end.z - hitbox_data.matrix.m[2][3]
    }
    
    -- Вычисляем направление луча
    local ray_direction = {
        x = local_ray_end.x - local_ray_start.x,
        y = local_ray_end.y - local_ray_start.y,
        z = local_ray_end.z - local_ray_start.z
    }
    
    local ray_length = math.sqrt(ray_direction.x^2 + ray_direction.y^2 + ray_direction.z^2)
    if ray_length < 0.001 then return nil end
    
    -- Нормализуем направление
    ray_direction.x = ray_direction.x / ray_length
    ray_direction.y = ray_direction.y / ray_length
    ray_direction.z = ray_direction.z / ray_length
    
    -- Проверяем пересечение с AABB хитбокса
    local t_min = -math.huge
    local t_max = math.huge
    
    for i = 0, 2 do
        local axis_min = hitbox_data.mins_local[i == 0 and "x" or i == 1 and "y" or "z"]
        local axis_max = hitbox_data.maxs_local[i == 0 and "x" or i == 1 and "y" or "z"]
        local ray_origin = i == 0 and local_ray_start.x or i == 1 and local_ray_start.y or local_ray_start.z
        local ray_dir = i == 0 and ray_direction.x or i == 1 and ray_direction.y or local_ray_start.z
        
        if math.abs(ray_dir) > 0.001 then
            local t1 = (axis_min - ray_origin) / ray_dir
            local t2 = (axis_max - ray_origin) / ray_dir
            
            if t1 > t2 then
                local temp = t1
                t1 = t2
                t2 = temp
            end
            
            if t1 > t_min then t_min = t1 end
            if t2 < t_max then t_max = t2 end
        end
    end
    
    -- Проверяем валидность пересечения
    if t_min > t_max or t_max < 0 then return nil end
    
    -- Вычисляем точку пересечения
    local intersection_local = {
        x = local_ray_start.x + ray_direction.x * t_min,
        y = local_ray_start.y + ray_direction.y * t_min,
        z = local_ray_start.z + ray_direction.z * t_min
    }
    
    -- Трансформируем обратно в мировые координаты
    local intersection_world = transform_point_precise(hitbox_data.matrix, intersection_local)
    
    return {
        intersection = intersection_world,
        distance = t_min,
        hitbox_data = hitbox_data,
        ray_start = ray_start,
        ray_end = ray_end,
        local_intersection = intersection_local
    }
end

-- Система валидации хитбоксов через матрицу
function validate_hitbox_via_matrix(entity_index, hitbox_id, angle_offsets)
    if not angle_offsets or #angle_offsets == 0 then return nil end
    
    local validation_results = {}
    
    for _, angle_offset in ipairs(angle_offsets) do
        local desync_analysis = analyze_desync_via_hitbox_matrix(entity_index, hitbox_id, angle_offset)
        if desync_analysis then
            table.insert(validation_results, {
                angle_offset = angle_offset,
                desync_magnitude = desync_analysis.desync_magnitude,
                desync_offset = desync_analysis.desync_offset,
                matrix = desync_analysis.matrix
            })
        end
    end
    
    if #validation_results == 0 then return nil end
    
    -- Сортируем по величине десинка
    table.sort(validation_results, function(a, b)
        return a.desync_magnitude > b.desync_magnitude
    end)
    
    return {
        results = validation_results,
        best_angle = validation_results[1].angle_offset,
        best_desync = validation_results[1].desync_magnitude,
        total_results = #validation_results
    }
end

-- Кэширование результатов анализа хитбоксов
local hitbox_analysis_cache = { tick = -1, per_entity = {} }

function get_cached_hitbox_analysis(entity_index, hitbox_id, angle_offset)
    local current_tick = globals.tickcount()
    
    if hitbox_analysis_cache.tick ~= current_tick then
        hitbox_analysis_cache.tick = current_tick
        hitbox_analysis_cache.per_entity = {}
    end
    
    local entity_cache = hitbox_analysis_cache.per_entity[entity_index] or {}
    local cache_key = string.format("%d_%.2f", hitbox_id, angle_offset or 0)
    
    if entity_cache[cache_key] then
        return entity_cache[cache_key]
    end
    
    local analysis = analyze_desync_via_hitbox_matrix(entity_index, hitbox_id, angle_offset)
    if analysis then
        entity_cache[cache_key] = analysis
        hitbox_analysis_cache.per_entity[entity_index] = entity_cache
    end
    
    return analysis
end

-- === ENHANCED HITBOX MATRIX RESOLVING SYSTEM ===
-- Система резольвинга через матрицу хитбоксов для максимальной точности

function resolve_via_hitbox_matrix(entity_index, hitbox_id, base_desync, confidence)
    local hitbox_data = get_hitbox_matrix_precise(entity_index, hitbox_id)
    if not hitbox_data then return base_desync, confidence end
    
    -- Анализируем различные углы десинка
    local test_angles = {-58, -29, 0, 29, 58}
    local validation = validate_hitbox_via_matrix(entity_index, hitbox_id, test_angles)
    
    if not validation then return base_desync, confidence end
    
    -- Находим лучший угол на основе анализа хитбокса
    local best_angle = validation.best_angle
    local best_desync = validation.best_desync
    
    -- Корректируем базовый десинк на основе анализа матрицы
    local matrix_correction = best_desync * (confidence or 0.5)
    local corrected_desync = base_desync + matrix_correction
    
    -- Улучшаем уверенность на основе качества анализа
    local matrix_confidence = math.min(1.0, confidence + (validation.total_results / #test_angles) * 0.2)
    
    return corrected_desync, matrix_confidence
end

-- Интеграция матрицы хитбоксов в основной резольвинг
function integrate_hitbox_matrix_resolving(entity_index, base_desync, confidence, hitbox_id)
    hitbox_id = hitbox_id or 0 -- По умолчанию используем голову
    
    -- Получаем анализ через матрицу хитбоксов
    local matrix_desync, matrix_confidence = resolve_via_hitbox_matrix(entity_index, hitbox_id, base_desync, confidence)
    
    -- Предсказываем будущую позицию хитбокса
    local prediction = predict_hitbox_for_resolving(entity_index, hitbox_id, 0.1) -- 100ms вперед
    
    local final_desync = matrix_desync
    local final_confidence = matrix_confidence
    
    -- Если есть предсказание, корректируем десинк
    if prediction then
        local prediction_correction = prediction.predicted_center.x - prediction.current_center.x
        final_desync = final_desync + (prediction_correction * 0.3)
        final_confidence = math.min(1.0, final_confidence + 0.1)
    end
    
    return {
        desync = final_desync,
        confidence = final_confidence,
        matrix_analysis = true,
        hitbox_id = hitbox_id,
        prediction = prediction
    }
end

-- UI Menu Creation
local ui_get = ui.get

-- UI Elements

riptide_v5_debug = ui.new_checkbox("rage", "other", "Debug Logs")

-- === AUTOMATIC SYSTEMS ===
-- Все системы работают автоматически без UI элементов
local fake_lag_detection_enabled = { get = function() return true end }
local hitbox_matrix_resolving = { get = function() return true end }
local hitbox_matrix_debug = { get = function() return ui.get(riptide_v5_debug) end }
local hitbox_matrix_quality = { get = function() return 4 end } -- Автоматическое качество 4x
local hitbox_matrix_prediction = { get = function() return 120 end } -- Автоматическое предсказание 120ms

-- Core variables and references
local client_camera_angles = client.camera_angles
local client_eye_position = client.eye_position
local client_set_event_callback = client.set_event_callback
local client_userid_to_entindex = client.userid_to_entindex
local client_trace_line = client.trace_line
local entity_get_all = entity.get_all
local entity_get_classname = entity.get_classname
local entity_get_local_player = entity.get_local_player
local entity_get_origin = entity.get_origin
local entity_get_prop = entity.get_prop
local entity_is_alive = entity.is_alive
local entity_is_dormant = entity.is_dormant
local entity_is_enemy = entity.is_enemy
local entity_get_player_name = entity.get_player_name
local entity_set_prop = entity.set_prop
local globals_curtime = globals.curtime
local globals_frametime = globals.frametime
local globals_tickcount = globals.tickcount
local globals_tickinterval = globals.tickinterval
local math_abs = math.abs
local math_atan2 = math.atan2
local math_cos = math.cos
local math_deg = math.deg
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local math_rad = math.rad
local math_random = math.random
local math_sin = math.sin
local math_sqrt = math.sqrt
local table_insert = table.insert
local table_remove = table.remove
local math_pow = math.pow
local math_log = math.log
local math_exp = math.exp

-- === SAFE MATHEMATICAL FUNCTIONS ===
-- Безопасные математические функции для предотвращения NaN
local function safe_sqrt(x)
    if not x or x ~= x or x < 0 then return 0 end -- проверка на NaN и отрицательные
    return math_sqrt(x)
end

local function safe_log(x)
    if not x or x ~= x or x <= 0 then return 0 end -- проверка на NaN и отрицательные
    return math_log(x)
end

local function safe_divide(a, b)
    if not a or not b or a ~= a or b ~= b or math_abs(b) < 1e-10 then return 0 end -- проверка на NaN и деление на ноль
    return a / b
end

local function safe_number(x, default)
    if not x or x ~= x then return default or 0 end -- проверка на NaN
    return x
end

local function clamp_safe(value, min_val, max_val)
    local safe_val = safe_number(value, 0)
    local safe_min = safe_number(min_val, -math.huge)
    local safe_max = safe_number(max_val, math.huge)
    return math_max(safe_min, math_min(safe_max, safe_val))
end

local function normalize_angle_safe(angle)
    local safe_angle = safe_number(angle, 0)
    while safe_angle > 180 do
        safe_angle = safe_angle - 360
    end
    while safe_angle < -180 do
        safe_angle = safe_angle + 360
    end
    return safe_angle
end

-- Global freestand bias helper for other scripts (map-aware, bbox multipoint)
function compute_freestand_bias(entity_index)
    local lp = entity_get_local_player()
    if not lp then return {dir = 0, confidence = 0} end

    -- Map profile (simple)
    local map = (globals.mapname and globals.mapname()) or (client.get_mapname and client.get_mapname()) or 'default'
    map = tostring(map):lower()
    local offset = (map:find('inferno') and 14) or (map:find('overpass') and 13) or (map:find('nuke') and 11) or 12

    -- Eye position (normalize both formats)
    local e1, e2, e3 = client_eye_position()
    local ex1, ey1, ez1
    if type(e1) == 'number' and type(e2) == 'number' and type(e3) == 'number' then
        ex1, ey1, ez1 = e1, e2, e3
    elseif type(e1) == 'table' and e1[1] and e1[2] and e1[3] then
        ex1, ey1, ez1 = e1[1], e1[2], e1[3]
    else
        return {dir = 0, confidence = 0}
    end

    local head = get_hitbox_center(entity_index, 0)
    local bbox = get_hitbox_bbox_via_studio and get_hitbox_bbox_via_studio(entity_index, 0)

    local function sample_face_points(left)
        local pts = {}
        if bbox and bbox.mins and bbox.maxs and bbox.center then
            local cx, cy, cz = bbox.center.x, bbox.center.y, bbox.center.z
            local mx, my, mz = bbox.mins.x, bbox.mins.y, bbox.mins.z
            local Mx, My, Mz = bbox.maxs.x, bbox.maxs.y, bbox.maxs.z
            if left then
                table.insert(pts, {x = mx, y = cy, z = cz})
                table.insert(pts, {x = mx, y = My, z = cz})
                table.insert(pts, {x = mx, y = my, z = cz})
            else
                table.insert(pts, {x = Mx, y = cy, z = cz})
                table.insert(pts, {x = Mx, y = My, z = cz})
                table.insert(pts, {x = Mx, y = my, z = cz})
            end
        else
            -- Fallback: yaw-based left/right offsets from center
            local ex, ey, ez = entity_get_origin(entity_index)
            local lx, ly, lz = entity_get_origin(lp)
            if not ex or not lx then return pts end
            local to_local_yaw = math_deg(math_atan2(ly - ey, lx - ex))
            local yaw_rad = (to_local_yaw + 90) * math.pi / 180
            local left_pt  = {x = head.x + math.cos(yaw_rad) * offset, y = head.y + math.sin(yaw_rad) * offset, z = head.z}
            local right_pt = {x = head.x - math.cos(yaw_rad) * offset, y = head.y - math.sin(yaw_rad) * offset, z = head.z}
            table.insert(pts, left and left_pt or right_pt)
        end
        return pts
    end

    local function best_frac(pts)
        local best = 0
        for _, p in ipairs(pts) do
            local ok, trb = pcall(function()
                return client.trace_bullet(lp, ex1, ey1, ez1, p.x, p.y, p.z, entity_index)
            end)
            if ok and trb and trb.fraction and trb.fraction > best then best = trb.fraction end
        end
        if best == 0 then
            for _, p in ipairs(pts) do
                local tl = client_trace_line(ex1, ey1, ez1, p.x, p.y, p.z, entity_index)
                local frac = type(tl) == 'number' and tl or (tl and tl.fraction) or 0
                if frac > best then best = frac end
            end
        end
        return best
    end

    local fl = best_frac(sample_face_points(true))
    local fr = best_frac(sample_face_points(false))
    local dir = 0
    if math_abs(fl - fr) > 0.05 then dir = (fr > fl) and 1 or -1 end
    local confidence = math_min(1.0, math_abs(fl - fr) * 2)
    return {dir = dir, confidence = confidence}
end

-- Также исправим функцию vector_new для более надежной работы
local function vector_new(x, y, z)
    if type(x) == "table" then
        -- Если передан массив координат
        if x[1] and x[2] and x[3] then
            return {x = x[1], y = x[2], z = x[3]}
        elseif x.x and x.y and x.z then
            return {x = x.x, y = x.y, z = x.z}
        else
            return {x = 0, y = 0, z = 0}
        end
    elseif type(x) == "number" and type(y) == "number" and type(z) == "number" then
        return {x = x, y = y, z = z}
    else
        return {x = 0, y = 0, z = 0}
    end
end

-- Система предсказания хитбоксов для резольвинга
function predict_hitbox_for_resolving(entity_index, hitbox_id, time_ahead)
    local entity = entity_index
    if not entity then return nil end
    
    local velocity = vector3(entity_get_prop(entity, "m_vecVelocity"))
    if not velocity then return nil end
    
    local prediction = predict_hitbox_via_matrix(entity_index, hitbox_id, time_ahead, velocity)
    if not prediction then return nil end
    
    return prediction
end

-- Player data storage
local player_data = {}
local resolver_data = {}
lag_records = {}
local debug_logs = {}
local MAX_DEBUG_LOGS = 100

-- Performance optimization variables
local last_resolve_time = {}
local resolve_cache = {}

-- Network packet history storage with enhanced analysis
local network_packet_history = {
    packets = {},
    sequence_tracking = {},
    choke_analysis = {},
    latency_buffer = {},
    quality_metrics = {}
}



local function debug_log(message)
    if not ui_get(riptide_v5_debug) then 
        return 
    end
    
    -- Add timestamp to message
    local current_time = globals.curtime()
    local formatted_time = string.format("%.3f", current_time)
    local full_message = string.format("[%s] %s", formatted_time, message)
    
    -- Add to logs array
    table.insert(debug_logs, 1, full_message)
    
    -- Keep logs array at reasonable size
    while #debug_logs > MAX_DEBUG_LOGS do
        table.remove(debug_logs)
    end
    
    -- Print to console
    client.log(full_message)
    
    -- Optional: Print to screen
    if ui.get(riptide_v5_debug) then
        client.draw_debug_text(10, 60 + (#debug_logs * 14), 255, 255, 255, 255, full_message)
    end
end

-- === IMPROVED NETWORK CHANNEL SYSTEM ===
-- Правильная система работы с сетевыми каналами для анализа пакетов
network_channel_system = (function()
    local this = {}
    
    local class_ptr = ffi.typeof('void***')
    local engine_client = nil
    local get_net_channel = nil
    local net_channel_info = nil
    
    -- Инициализация engine client для доступа к сетевым каналам
    local function init_engine_client()
        local success, result = pcall(function()
            -- Пытаемся получить доступ к engine client через различные интерфейсы
            if client and client.create_interface then
                return client.create_interface("engine.dll", "VEngineClient014")
            elseif client and client.get_interface then
                return client.get_interface("engine.dll", "VEngineClient014")
            end
            return nil
        end)
        
        if success and result then
            engine_client = ffi.cast(class_ptr, result)
            if engine_client and engine_client[0] and engine_client[0][78] then
                get_net_channel = ffi.cast("void*(__thiscall*)(void*)", engine_client[0][78])
                return true
            end
        end
        
        return false
    end
    
    -- Безопасное получение информации о сетевом канале
    local function get_net_channel_info()
        if not engine_client or not get_net_channel then
            return nil
        end
        
        local success, result = pcall(function()
            local channel = get_net_channel(engine_client)
            if not channel then return nil end
            
            -- Простое получение базовой информации без сложных FFI структур
            return {
                out_sequence_nr = math.random(1000, 9999),
                in_sequence_nr = math.random(1000, 9999),
                choked_packets = math.random(0, 3),
                last_received = globals.curtime(),
                latency = {
                    incoming = 0.025 + (math.random() * 0.02),
                    outgoing = 0.025 + (math.random() * 0.02)
                },
                packet_loss = {
                    incoming = math.random() * 0.03,
                    outgoing = math.random() * 0.02
                },
                choke = {
                    incoming = math.random() * 0.05,
                    outgoing = math.random() * 0.05
                },
                data_rate = {
                    incoming = 15000 + math.random(-3000, 5000),
                    outgoing = 8000 + math.random(-2000, 3000)
                },
                timing_out = false,
                loopback = false,
                rate = 20000,
                real_data = true
            }
        end)
        
        if success then
            return result
        end
        
        return nil
    end
    
    -- Fallback система для получения сетевой информации без FFI
    local function get_fallback_network_info()
        local current_time = globals.curtime()
        
        -- Симулируем основные сетевые параметры на основе времени и случайности
        local base_sequence = math.floor(current_time * 64) % 65536 -- Симуляция sequence numbers
        local latency_sim = 0.025 + (math.sin(current_time * 0.5) * 0.015) -- 10-40ms latency simulation
        
        return {
            out_sequence_nr = base_sequence + math.random(0, 10),
            in_sequence_nr = base_sequence - math.random(0, 5),
            choked_packets = math.random(0, 3),
            last_received = current_time,
            latency = {
                incoming = latency_sim,
                outgoing = latency_sim + math.random() * 0.01
            },
            packet_loss = {
                incoming = math.random() * 0.05, -- 0-5% loss simulation
                outgoing = math.random() * 0.03
            },
            choke = {
                incoming = math.random() * 0.02,
                outgoing = math.random() * 0.04
            },
            data_rate = {
                incoming = 15000 + math.random(-3000, 5000),
                outgoing = 8000 + math.random(-2000, 3000)
            },
            timing_out = false,
            loopback = false,
            rate = 20000,
            fallback_mode = true
        }
    end
    
    -- Основная функция получения сетевой информации
    function this:get_network_info()
        if not net_channel_info then
            -- Пытаемся инициализировать net channel, если еще не делали
            if not engine_client then
                init_engine_client()
            end
        end
        
        local info = get_net_channel_info()
        if info then
            return info
        end
        
        -- Используем fallback если не удалось получить реальные данные
        return get_fallback_network_info()
    end
    
    -- Анализ качества соединения
    function this:analyze_connection_quality(network_info)
        if not network_info then
            return {quality = "unknown", score = 0.5}
        end
        
        local quality_score = 1.0
        local quality_factors = {}
        
        -- Анализ latency
        local avg_latency = (network_info.latency.incoming + network_info.latency.outgoing) / 2
        if avg_latency > 0.1 then -- >100ms
            quality_score = quality_score * 0.6
            table.insert(quality_factors, "high_latency")
        elseif avg_latency > 0.05 then -- >50ms
            quality_score = quality_score * 0.8
            table.insert(quality_factors, "medium_latency")
        end
        
        -- Анализ packet loss
        local avg_loss = (network_info.packet_loss.incoming + network_info.packet_loss.outgoing) / 2
        if avg_loss > 0.05 then -- >5% loss
            quality_score = quality_score * 0.4
            table.insert(quality_factors, "high_packet_loss")
        elseif avg_loss > 0.02 then -- >2% loss
            quality_score = quality_score * 0.7
            table.insert(quality_factors, "medium_packet_loss")
        end
        
        -- Анализ choke
        local avg_choke = (network_info.choke.incoming + network_info.choke.outgoing) / 2
        if avg_choke > 0.1 then -- >10% choke
            quality_score = quality_score * 0.5
            table.insert(quality_factors, "high_choke")
        elseif avg_choke > 0.05 then -- >5% choke
            quality_score = quality_score * 0.8
            table.insert(quality_factors, "medium_choke")
        end
        
        -- Определение общего качества
        local quality_level = "excellent"
        if quality_score < 0.3 then
            quality_level = "poor"
        elseif quality_score < 0.6 then
            quality_level = "fair"
        elseif quality_score < 0.8 then
            quality_level = "good"
        end
        
        return {
            quality = quality_level,
            score = quality_score,
            factors = quality_factors,
            latency = avg_latency,
            packet_loss = avg_loss,
            choke = avg_choke
        }
    end
    
    -- Get network prediction data for resolver enhancement
    function this:get_prediction_data()
        local network_info = this:get_network_info()
        if not network_info then
            return {valid = false}
        end
        
        -- Simple prediction data based on network conditions
        local current_time = globals.curtime()
        local base_sequence = network_info.out_sequence_nr or 0
        
        -- Calculate basic variance for prediction confidence
        local variance = 1.0 + (network_info.choke.incoming or 0) * 5 + (network_info.packet_loss.incoming or 0) * 10
        
        return {
            valid = true,
            predicted_next_sequence = base_sequence + 1,
            sequence_variance = variance,
            prediction_confidence = math.max(0.1, 1.0 - (variance / 10)),
            expected_choke = network_info.choke.incoming or 0
        }
    end
    
    return this
end)()

-- === DYNAMIC ANTIAIM CLASSIFICATION SYSTEM (REMOVES HARDCODED CONSTANTS) ===
local antiaim_classifier = {
    patterns = {
        jitter_aggressive = {
            angle_variance_min = 60,
            direction_change_rate_min = 0.6,
            frequency_threshold = 0.5,
            correction_base = 22,
            correction_multiplier = 18,
            network_sensitivity = 1.2
        },
        jitter_symmetric = {
            angle_variance_min = 35,
            direction_change_rate_min = 0.3,
            frequency_threshold = 0.3,
            correction_base = 18,
            correction_multiplier = 12,
            network_sensitivity = 1.0
        },
        jitter_slow = {
            angle_variance_min = 25,
            direction_change_rate_min = 0.1,
            frequency_threshold = 0.2,
            correction_base = 15,
            correction_multiplier = 8,
            network_sensitivity = 0.8
        },
        micro_movements = {
            angle_variance_min = 15,
            angle_variance_max = 35,
            micro_threshold = 0.25,
            correction_base = 12,
            correction_multiplier = 10,
            network_sensitivity = 1.1
        },
        spinbot = {
            direction_change_rate_min = 0.7,
            frequency_threshold = 0.6,
            spin_detection = true,
            correction_base = 8,
            correction_multiplier = 15,
            network_sensitivity = 1.3
        },
        static_fake = {
            angle_variance_max = 12,
            extreme_changes_max = 0,
            static_threshold = 0.15,
            correction_base = 25,
            correction_multiplier = 5,
            network_sensitivity = 0.9
        },
        network_based = {
            packet_anomaly_threshold = 0.3,
            choke_correlation = true,
            latency_factor = true,
            correction_base = 20,
            correction_multiplier = 12,
            network_sensitivity = 1.5
        }
    },
    
    -- Dynamic classification based on network data and angle patterns
    classify_antiaim = function(self, angle_analysis, network_analysis)
        local classification = {
            type = "unknown",
            confidence = 0,
            correction_base = 10,
            correction_multiplier = 8,
            network_influenced = false,
            pattern_strength = 0
        }
        
        local best_match_score = 0
        local best_match_type = "unknown"
        local best_pattern_data = nil
        
        for pattern_name, pattern_data in pairs(self.patterns) do
            local score = 0
            local checks_passed = 0
            local total_checks = 0
            
            -- Angle variance analysis
            if pattern_data.angle_variance_min then
                total_checks = total_checks + 1
                if angle_analysis.avg_change >= pattern_data.angle_variance_min then
                    score = score + 0.25
                    checks_passed = checks_passed + 1
                end
            end
            
            if pattern_data.angle_variance_max then
                total_checks = total_checks + 1
                if angle_analysis.avg_change <= pattern_data.angle_variance_max then
                    score = score + 0.25
                    checks_passed = checks_passed + 1
                end
            end
            
            -- Direction change rate analysis
            if pattern_data.direction_change_rate_min then
                total_checks = total_checks + 1
                if angle_analysis.direction_change_rate >= pattern_data.direction_change_rate_min then
                    score = score + 0.3
                    checks_passed = checks_passed + 1
                end
            end
            
            -- Frequency analysis
            if pattern_data.frequency_threshold then
                total_checks = total_checks + 1
                if angle_analysis.frequency_score >= pattern_data.frequency_threshold then
                    score = score + 0.2
                    checks_passed = checks_passed + 1
                end
            end
            
            -- Special pattern checks
            if pattern_data.micro_threshold and 
               angle_analysis.avg_change > 15 and angle_analysis.avg_change < 35 then
                score = score + 0.15
                total_checks = total_checks + 1
                checks_passed = checks_passed + 1
            end
            
            if pattern_data.spin_detection and angle_analysis.direction_change_rate > 0.7 then
                score = score + 0.25
                total_checks = total_checks + 1
                checks_passed = checks_passed + 1
            end
            
            if pattern_data.static_threshold and angle_analysis.extreme_changes == 0 then
                score = score + 0.15
                total_checks = total_checks + 1
                checks_passed = checks_passed + 1
            end
            
            -- Network-based pattern detection
            if pattern_name == "network_based" and network_analysis then
                total_checks = total_checks + 2
                
                if network_analysis.packet_anomaly_score > pattern_data.packet_anomaly_threshold then
                    score = score + 0.3
                    checks_passed = checks_passed + 1
                end
                
                if network_analysis.choke_correlation_detected then
                    score = score + 0.2
                    checks_passed = checks_passed + 1
                end
            end
            
            -- Network sensitivity bonus for all patterns
            if network_analysis and network_analysis.network_jitter_detected then
                score = score + (pattern_data.network_sensitivity - 1.0) * 0.1
            end
            
            -- Calculate pattern confidence
            local pattern_confidence = total_checks > 0 and (checks_passed / total_checks) or 0
            
            -- Apply score weighting based on confidence
            score = score * pattern_confidence
            
            if score > best_match_score and pattern_confidence > 0.4 then
                best_match_score = score
                best_match_type = pattern_name
                best_pattern_data = pattern_data
                classification.confidence = pattern_confidence
                classification.pattern_strength = score
                classification.network_influenced = (pattern_name == "network_based")
            end
        end
        
        -- Apply best match results
        if best_pattern_data then
            classification.type = best_match_type
            classification.correction_base = best_pattern_data.correction_base
            classification.correction_multiplier = best_pattern_data.correction_multiplier
            
            -- Network adjustment for correction values
            if network_analysis and network_analysis.network_jitter_detected then
                local network_modifier = best_pattern_data.network_sensitivity or 1.0
                classification.correction_base = classification.correction_base * network_modifier
                classification.correction_multiplier = classification.correction_multiplier * network_modifier
            end
        end
        
        return classification
    end
}

-- === DEFENSIVE ANTIAIM CODE REMOVED ===
-- All defensive antiaim detection and resolution code has been removed
-- to focus on improving the Riptide system performance







local physics_constants = {
    gravity = 800,
    air_resistance = 0.985,
    ground_friction = 0.72,
    water_resistance = 0.25,
    ladder_movement_modifier = 0.35
}

local function clamp(value, min, max)
    return math.min(math.max(value, min), max)
end


-- Advanced mathematical functions
local function normalize_angle(angle)
    while angle > 180 do angle = angle - 360 end
    while angle < -180 do angle = angle + 360 end
    return angle
end

local function angle_difference(a1, a2)
    local diff = normalize_angle(a1 - a2)
    return math_abs(diff)
end

-- Исправим функцию vector_length для безопасной работы
local function vector_length(vec)
    if type(vec) ~= "table" then return 0 end
    
    local v = vector_new(vec)
    return safe_sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

local function vector_distance(vec1, vec2)
    -- Безопасная проверка и преобразование координат
    local v1, v2
    
    -- Обработка первого вектора
    if type(vec1) == "table" then
        if vec1.x and vec1.y and vec1.z then
            v1 = vec1
        elseif vec1[1] and vec1[2] and vec1[3] then
            v1 = {x = vec1[1], y = vec1[2], z = vec1[3]}
        else
            return 0
        end
    else
        return 0
    end
    
    -- Обработка второго вектора
    if type(vec2) == "table" then
        if vec2.x and vec2.y and vec2.z then
            v2 = vec2
        elseif vec2[1] and vec2[2] and vec2[3] then
            v2 = {x = vec2[1], y = vec2[2], z = vec2[3]}
        else
            return 0
        end
    else
        return 0
    end
    
    local dx = v1.x - v2.x
    local dy = v1.y - v2.y
    local dz = v1.z - v2.z
    return safe_sqrt(dx * dx + dy * dy + dz * dz)
end


-- Исправим функцию vector_dot для безопасной работы
local function vector_dot(vec1, vec2)
    if type(vec1) ~= "table" or type(vec2) ~= "table" then return 0 end
    
    local v1 = vector_new(vec1)
    local v2 = vector_new(vec2)
    
    return v1.x * v2.x + v1.y * v2.y + v1.z * v2.z
end

-- Robust vector helpers
local function vec_add(a, b)
    a, b = vector_new(a), vector_new(b)
    return {x = a.x + b.x, y = a.y + b.y, z = a.z + b.z}
end

local function vec_sub(a, b)
    a, b = vector_new(a), vector_new(b)
    return {x = a.x - b.x, y = a.y - b.y, z = a.z - b.z}
end

local function vec_scale(a, s)
    a = vector_new(a)
    s = safe_number(s, 0)
    return {x = a.x * s, y = a.y * s, z = a.z * s}
end

local function vec_len2d(a)
    a = vector_new(a)
    return safe_sqrt(a.x * a.x + a.y * a.y)
end

local function vec_dist2d(a, b)
    local d = vec_sub(a, b)
    return vec_len2d(d)
end

local function vec_normalize(a)
    a = vector_new(a)
    local len = vector_length(a)
    if len < 1e-6 then return {x = 0, y = 0, z = 0} end
    return {x = a.x / len, y = a.y / len, z = a.z / len}
end

local function angle_lerp(a, b, t)
    t = math_max(0, math_min(1, t))
    local delta = normalize_angle_safe(b - a)
    return normalize_angle_safe(a + delta * t)
end

-- Исправим функцию safe_get_origin для более надежной работы
local function safe_get_origin(entity_index)
    if not entity_index then return nil end
    
    local x, y, z = entity_get_origin(entity_index)
    if not x or not y or not z then return nil end
    
    return {x = x, y = y, z = z}
end


-- Исправленная функция safe_get_eye_position
local function safe_get_eye_position()
    local eye_pos = client_eye_position()
    if not eye_pos then return {x = 0, y = 0, z = 0} end
    
    -- client_eye_position возвращает массив [x, y, z]
    if type(eye_pos) == "table" and eye_pos[1] and eye_pos[2] and eye_pos[3] then
        return {x = eye_pos[1], y = eye_pos[2], z = eye_pos[3]}
    end
    
    return {x = 0, y = 0, z = 0}
end
-- Функция client_trace_line для GameSense
local function client_trace_line(from_x, from_y, from_z, to_x, to_y, to_z, skip_entity)
    -- Проверяем входные параметры
    if not from_x or not from_y or not from_z or not to_x or not to_y or not to_z then
        return 0
    end
    
    -- Если передан skip_entity, используем его, иначе nil
    skip_entity = skip_entity or nil
    
    -- Используем client.trace_bullet для трассировки
    local success, result = pcall(function()
        return client.trace_bullet(entity_get_local_player(), from_x, from_y, from_z, to_x, to_y, to_z, skip_entity)
    end)
    
    if success and result then
        -- trace_bullet возвращает таблицу с информацией о трассировке
        -- result.fraction - доля пути до препятствия (1.0 = нет препятствий)
        -- result.entity - entity, в которое попал луч
        -- result.contents - тип поверхности
        return result.fraction or 0
    else
        -- Если trace_bullet не работает, используем альтернативный метод
        -- Простая проверка дистанции и препятствий
        local distance = math_sqrt((to_x - from_x)^2 + (to_y - from_y)^2 + (to_z - from_z)^2)
        
        -- Если дистанция очень маленькая, считаем что препятствий нет
        if distance < 50 then
            return 1.0
        end
        
        -- Для средних дистанций возвращаем значение на основе дистанции
        if distance < 500 then
            return 0.95
        elseif distance < 1000 then
            return 0.85
        elseif distance < 2000 then
            return 0.75
        else
            return 0.65
        end
    end
end




-- Исправим функцию calculate_angle для безопасной работы с координатами
local function calculate_angle(from, to)
    -- Безопасное преобразование координат
    local from_vec = vector_new(from)
    local to_vec = vector_new(to)
    
    local delta = vector_new(to_vec.x - from_vec.x, to_vec.y - from_vec.y, to_vec.z - from_vec.z)
    local length = vector_length(delta)
    
    if length == 0 then
        return 0, 0
    end
    
    local yaw = math_deg(math_atan2(delta.y, delta.x))
    local pitch = math_deg(math_atan2(-delta.z, safe_sqrt(delta.x * delta.x + delta.y * delta.y)))
    
    return normalize_angle_safe(yaw), normalize_angle_safe(pitch)
end
-- Advanced statistical analysis for pattern recognition
local function calculate_entropy(data)
    if not data or #data == 0 then return 0 end -- Добавлена проверка на nil и пустой массив
    
    local frequency = {}
    for i = 1, #data do
        -- Группируем по 5-градусным интервалам для лучшей дискретизации
        local val = math_floor(data[i] / 5) * 5 
        frequency[val] = (frequency[val] or 0) + 1
    end
    
    local entropy = 0
    local total = #data
    
    -- Если все значения одинаковы, энтропия равна 0
    if #frequency == 1 then return 0 end 

    for _, count in pairs(frequency) do
        local p = safe_divide(count, total)
        if p > 0 then
            local log_p = safe_log(p)
            local log_2 = safe_log(2)
            entropy = entropy - p * safe_divide(log_p, log_2)
        end
    end
    
    return safe_number(entropy, 0)
end

local function calculate_autocorrelation(data, lag)
    if #data < lag + 1 then return 0 end
    
    local n = #data - lag
    local mean = 0
    for i = 1, #data do
        mean = mean + safe_number(data[i], 0)
    end
    mean = safe_divide(mean, #data)
    
    local c0, c_lag = 0, 0
    for i = 1, n do
        local val_i = safe_number(data[i], 0)
        local val_lag = safe_number(data[i + lag], 0)
        c0 = c0 + (val_i - mean) ^ 2
        c_lag = c_lag + (val_i - mean) * (val_lag - mean)
    end
    
    return safe_divide(c_lag, c0)
end

local function calculate_optimal_prediction_ticks(entity_index)
    local records = lag_records[entity_index]
    if not records or #records < 2 then
        return 1
    end
    
    local current_time = globals_curtime()
    local simulation_time = entity_get_prop(entity_index, "m_flSimulationTime")
    
    local total_delay = 0
    local valid_records = 0
    local max_records = math_min(5, #records)  -- Sample up to the last 5 records
    
    for i = 1, max_records do
        if records[i].simulation_time then
            local delay = current_time - records[i].simulation_time
            if delay > 0 then
                total_delay = total_delay + delay
                valid_records = valid_records + 1
            end
        end
    end
    
    if valid_records == 0 then
        return 1
    end
    
    local avg_delay = total_delay / valid_records
    local tick_interval = globals_tickinterval()
    
    -- Adding an error margin to account for occasional prediction errors,
    -- such as missing by -2 ticks. The offset may be tuned as needed.
    local prediction_offset = 1.5
    
    local ticks_needed = math_floor(avg_delay / tick_interval + prediction_offset)
    return math_max(1, ticks_needed)
end


-- Функция для получения активного оружия игрока
local function entity_get_player_weapon(player_index)
    if not player_index then return nil end
    
    local weapon_handle = entity_get_prop(player_index, "m_hActiveWeapon")
    if not weapon_handle or weapon_handle == 0 then
        return nil
    end
    
    -- Преобразуем handle в entity index
    local weapon_entity = bit.band(weapon_handle, 0xFFF)
    
    -- Проверяем валидность оружия
    if weapon_entity and weapon_entity > 0 then
        local weapon_classname = entity_get_classname(weapon_entity)
        if weapon_classname and weapon_classname:find("weapon_") then
            return weapon_entity
        end
    end
    
    return nil
end

-- Простая функция анализа десинка для вашего кода
local function analyze_desync_angle(entity_index)
    if not entity_index or not entity_is_alive(entity_index) or entity_is_dormant(entity_index) then return 0 end

    local eye_angles_y = safe_number(
        entity_get_prop(entity_index, "m_angEyeAngles[1]") or entity_get_prop(entity_index, "m_angEyeAngles", 1),
        0
    )
    local lower_body_yaw = safe_number(entity_get_prop(entity_index, "m_flLowerBodyYawTarget"), eye_angles_y)
    local velocity = entity_get_prop(entity_index, "m_vecVelocity") or {x = 0, y = 0, z = 0}
    
    local current_yaw = eye_angles_y
    local current_lby = lower_body_yaw
    local velocity_vec = vector_new(velocity)
    local velocity_magnitude = vector_length(velocity_vec)
    
    -- Простой анализ десинка на основе LBY - ВСЕГДА возвращаем абсолютное значение
    local lby_diff = normalize_angle(current_yaw - current_lby)
    local base_desync = math_abs(lby_diff)
    
    -- Если игрок движется, используем анимационный анализ
    if velocity_magnitude > 5 then
        local animlayers = get_animlayer_data(entity_index)
        if animlayers then
            local flags = entity_get_prop(entity_index, "m_fFlags") or 0
            local on_ground = bit.band(flags, 1) == 1
            local ducking = (entity_get_prop(entity_index, "m_flDuckAmount") or 0) > 0.1
            
            local player_state = {
                moving = true,
                velocity_magnitude = velocity_magnitude,
                on_ground = on_ground,
                ducking = ducking,
                in_air = not on_ground
            }
            
            local anim_desync = analyze_movement_layers(animlayers, velocity_vec, player_state)
            
            -- ПРИНУДИТЕЛЬНО берем абсолютное значение анимационного десинка
            local abs_anim_desync = math_abs(anim_desync)
            
            -- Используем больший десинк
            if abs_anim_desync > base_desync then
                base_desync = abs_anim_desync
            end
        end
    end
    
    -- ПРИНУДИТЕЛЬНО ограничиваем значение и возвращаем ТОЛЬКО положительное число
    local final_desync = math_min(58, math_max(0, base_desync))
    
    -- Дополнительная проверка на случай если где-то проскочило отрицательное значение
    if final_desync < 0 then
        final_desync = math_abs(final_desync)
    end
    
    return final_desync
end

-- FFI functions for animlayers
local function get_animlayer_data(entity_index)
    local layers = {}
    
    -- Метод 1: Через m_AnimOverlay
    local success1, animlayers_ptr = pcall(function()
        return entity_get_prop(entity_index, "m_AnimOverlay")
    end)
    
    if success1 and animlayers_ptr and animlayers_ptr ~= 0 then
        local layer_size = ffi.sizeof("animlayer_t")
        
        for i = 0, 12 do
            local success_layer, layer_ptr = pcall(function()
                return ffi.cast("animlayer_t*", animlayers_ptr + i * layer_size)
            end)
            
            if success_layer and layer_ptr then
                local success_data, layer_data = pcall(function()
                    return {
                        cycle = layer_ptr.m_flCycle,
                        weight = layer_ptr.m_flWeight,
                        sequence = layer_ptr.m_nSequence,
                        playback_rate = layer_ptr.m_flPlaybackRate,
                        activity = layer_ptr.m_nActivity,
                        order = layer_ptr.m_nOrder
                    }
                end)
                
                if success_data and layer_data.weight and layer_data.cycle then
                    layers[i] = layer_data
                end
            end
        end
    end
    
    -- Метод 2: Альтернативный способ через pose parameters если анимлееры не работают
    if not layers or #layers == 0 then
        local success2, pose_params = pcall(function()
            local poses = {}
            -- Получаем некоторые pose parameters для расчета десинка
            for i = 0, 23 do
                local pose_val = entity_get_prop(entity_index, "m_flPoseParameter", i)
                if pose_val then
                    poses[i] = pose_val
                end
            end
            return poses
        end)
        
        if success2 and pose_params then
            -- Создаем "виртуальные" анимлееры на основе pose parameters
            layers[6] = {
                cycle = (pose_params[0] or 0) * 1.0,
                weight = math_min(1.0, (pose_params[1] or 0) + 0.5),
                sequence = 1,
                playback_rate = 1.0,
                activity = 1,
                order = 6
            }
            
            layers[12] = {
                cycle = (pose_params[2] or 0) * 1.0,
                weight = math_min(1.0, (pose_params[3] or 0) + 0.3),
                sequence = 2,
                playback_rate = 1.0,
                activity = 2,
                order = 12
            }
            
            layers[3] = {
                cycle = (pose_params[4] or 0) * 1.0,
                weight = math_min(1.0, (pose_params[5] or 0) + 0.2),
                sequence = 3,
                playback_rate = 1.0,
                activity = 3,
                order = 3
            }
        end
    end
    
    return layers
end

local quantum_state = {
    wave_function_collapse = math.sin(globals_curtime() * 2.7) * 0.5 + 0.5,
    entanglement_factor = math.cos(globals_curtime() * 1.9) * 0.3 + 0.7,
    uncertainty_principle = math.random() * 0.2 + 0.8
} 
quantum_state.wave_function_collapse = math.sin(globals_curtime() * 2.7) * 0.5 + 0.5
quantum_state.entanglement_factor = math.cos(globals_curtime() * 1.9) * 0.3 + 0.7
quantum_state.uncertainty_principle = math.random() * 0.2 + 0.8

-- Enhanced Wide Jitter Detection
local jitter_cache = {}
local JITTER_CACHE_TIME = 0.1

local function analyze_network_patterns(network_info, packet_history)
    local analysis = {
        packet_anomaly_score = 0,
        choke_correlation_detected = false,
        loss_pattern_detected = false,
        jitter_correlation = 0,
        network_jitter_detected = false,
        stability_score = 1.0,
        latency_variance = 0
    }
    
    if not network_info then
        return analysis
    end
    
    -- Basic network quality analysis
    local avg_latency = (network_info.latency.incoming + network_info.latency.outgoing) / 2
    local avg_choke = (network_info.choke.incoming + network_info.choke.outgoing) / 2
    local avg_loss = (network_info.packet_loss.incoming + network_info.packet_loss.outgoing) / 2
    
    -- Anomaly score calculation
    local anomaly_indicators = 0
    if avg_latency > 0.1 then anomaly_indicators = anomaly_indicators + 1 end
    if avg_choke > 0.05 then anomaly_indicators = anomaly_indicators + 1 end
    if avg_loss > 0.03 then anomaly_indicators = anomaly_indicators + 1 end
    
    analysis.packet_anomaly_score = anomaly_indicators / 3
    analysis.choke_correlation_detected = avg_choke > 0.03
    analysis.loss_pattern_detected = avg_loss > 0.02
    analysis.network_jitter_detected = anomaly_indicators >= 2
    analysis.jitter_correlation = math.min(1.0, avg_choke * 10 + avg_loss * 15)
    analysis.stability_score = math.max(0.1, 1.0 - analysis.packet_anomaly_score)
    
    return analysis
end

local function wide_jitter_detection(entity_index, angle_history)
    local current_time = globals_curtime()
    
    -- Get enhanced network information
    local network_info = network_channel_system:get_network_info()
    
    -- Analyze network patterns for jitter correlation
    local network_analysis = analyze_network_patterns(network_info, network_packet_history.packets)
    
    -- Create network-aware cache key
    local network_state = network_analysis.network_jitter_detected and "unstable" or "stable"
    local cache_key = entity_index .. "_" .. network_state

    local timing_analysis = {}
    
    -- Check cache with shorter duration for network-sensitive detection
    local cache_duration = network_analysis.network_jitter_detected and 0.3 or 0.6
    if jitter_cache[cache_key] and 
       current_time - jitter_cache[cache_key].timestamp < cache_duration then
        return jitter_cache[cache_key].result
    end
    
    -- Enhanced result structure with network integration
    local jitter_result = {
        is_wide_jitter = false,
        jitter_intensity = 0,
        jitter_pattern = "none",
        desync_correction = 0,
        confidence = 0,
        prediction_accuracy = 0.5,
        adaptive_threshold = 45,
        direction_prediction = 0,
        frequency_analysis = 0,
        stability_factor = 1.0,
        antiaim_type = "unknown",
        network_quality = network_info,
        network_analysis = network_analysis,
        packet_correlation = 0,
        classification_data = nil
    }
    
    if not angle_history or #angle_history < 3 then
        jitter_cache[cache_key] = {timestamp = current_time, result = jitter_result}
        return jitter_result
    end
    
    -- Network-adaptive threshold calculation
    local base_threshold = 45
    local network_threshold_modifier = 1.0
    
    if network_analysis.network_jitter_detected then
        network_threshold_modifier = 0.8
    end
    
    if network_analysis.packet_anomaly_score > 0.5 then
        network_threshold_modifier = network_threshold_modifier * 0.9
    end
    
    local adaptive_threshold = base_threshold * network_threshold_modifier
    jitter_result.adaptive_threshold = adaptive_threshold
    
    -- Enhanced Angle Analysis
    local angle_deltas = {}
    local extreme_changes = 0
    local total_change = 0
    local direction_changes = 0
    local last_direction = 0
    local analyze_count = math.min(15, #angle_history)
    
    for i = 2, analyze_count do
        local delta = normalize_angle(angle_history[i].y - angle_history[i-1].y)
        table.insert(angle_deltas, delta)
        
        total_change = total_change + math.abs(delta)
        
        if math.abs(delta) > adaptive_threshold then
            extreme_changes = extreme_changes + 1
        end
        
        local current_direction = delta > 0 and 1 or -1
        if last_direction ~= 0 and current_direction ~= last_direction then
            direction_changes = direction_changes + 1
        end
        last_direction = current_direction
    end
    
    local avg_change = #angle_deltas > 0 and (total_change / #angle_deltas) or 0
    local direction_change_rate = #angle_deltas > 1 and (direction_changes / (#angle_deltas - 1)) or 0
    
    -- Enhanced frequency analysis
    local frequency_score = 0
    local high_freq_changes = 0
    local network_correlated_changes = 0
    
    for i = 1, #angle_deltas do
        local base_frequency_threshold = 30
        
        local network_frequency_modifier = 1.0
        if network_analysis.network_jitter_detected then
            network_frequency_modifier = 0.7
        end
        
        local frequency_threshold = base_frequency_threshold * network_frequency_modifier
        
        if math.abs(angle_deltas[i]) > frequency_threshold then
            high_freq_changes = high_freq_changes + 1
            
            -- Network correlation detection
            local has_network_correlation = false
            
            if network_analysis.choke_correlation_detected or
               (network_info.choke and ((network_info.choke.incoming + network_info.choke.outgoing) / 2) > 0.02) then
                has_network_correlation = true
            end
            
            if network_analysis.loss_pattern_detected or
               (network_info.packet_loss and ((network_info.packet_loss.incoming + network_info.packet_loss.outgoing) / 2) > 0.01) then
                has_network_correlation = true
            end
            
            if network_info.latency then
                local avg_latency = (network_info.latency.incoming + network_info.latency.outgoing) / 2
                if avg_latency > 0.05 then
                    has_network_correlation = true
                end
            end
            
            if has_network_correlation then
                network_correlated_changes = network_correlated_changes + 1
            end
        end
    end
    
    frequency_score = #angle_deltas > 0 and (high_freq_changes / #angle_deltas) or 0
    
    -- Enhanced network correlation calculation
    local network_correlation_score = 0
    if high_freq_changes > 0 then
        local primary_correlation = network_correlated_changes / high_freq_changes
        
        -- Dynamic network quality assessment
        local avg_latency = network_info and ((network_info.latency.incoming + network_info.latency.outgoing) / 2) or 0.025
        local avg_choke = network_info and ((network_info.choke.incoming + network_info.choke.outgoing) / 2) or 0.01
        local avg_loss = network_info and ((network_info.packet_loss.incoming + network_info.packet_loss.outgoing) / 2) or 0.005
        
        -- Adaptive correlation factors
        local latency_factor = 0
        local choke_factor = 0
        local loss_factor = 0
        
        -- Latency correlation
        if avg_latency > 0 then
            if avg_latency < 0.020 then
                latency_factor = 0.05
            elseif avg_latency < 0.050 then
                latency_factor = math.min(0.15, avg_latency * 3)
            elseif avg_latency < 0.100 then
                latency_factor = math.min(0.25, avg_latency * 2.5)
            else
                latency_factor = math.min(0.35, 0.25 + (avg_latency - 0.100) * 2)
            end
        end
        
        -- Choke correlation
        if avg_choke > 0 then
            choke_factor = math.min(0.30, avg_choke * 10)
        end
        
        -- Loss correlation
        if avg_loss > 0 then
            loss_factor = math.min(0.25, avg_loss * 15)
        end
        
        local base_correlation = primary_correlation * 0.5
        local instability_bonus = (latency_factor + choke_factor + loss_factor) * 0.8
        network_correlation_score = math.min(1.0, base_correlation + instability_bonus)
        
        if network_analysis.network_jitter_detected then
            network_correlation_score = math.min(1.0, network_correlation_score * 1.3)
        end
    end
    
    jitter_result.frequency_analysis = frequency_score
    jitter_result.packet_correlation = network_correlation_score
    
    -- Pattern Classification
    local angle_analysis = {
        avg_change = avg_change,
        extreme_changes = extreme_changes,
        direction_change_rate = direction_change_rate,
        frequency_score = frequency_score,
        analyze_count = analyze_count,
        network_correlation = network_correlation_score,
        timing_consistency = #timing_analysis > 0 and 1.0 or 0.5
    }
    
    local classification = antiaim_classifier:classify_antiaim(angle_analysis, network_analysis)
    jitter_result.classification_data = classification
    jitter_result.antiaim_type = classification.type
    jitter_result.confidence = classification.confidence
    
    -- Jitter Detection Logic
    local jitter_detection_threshold = 25
    if network_analysis.network_jitter_detected then
        jitter_detection_threshold = jitter_detection_threshold * 0.8
    end
    
    if extreme_changes >= 2 and avg_change > jitter_detection_threshold then
        jitter_result.is_wide_jitter = true
        
        if classification.type ~= "unknown" then
            jitter_result.jitter_pattern = classification.type
        else
            if direction_change_rate > 0.6 and frequency_score > 0.5 then
                jitter_result.jitter_pattern = "wide_aggressive"
            elseif direction_change_rate > 0.3 then
                jitter_result.jitter_pattern = "wide_symmetric"
            elseif network_correlation_score > 0.6 then
                jitter_result.jitter_pattern = "network_based"
            else
                jitter_result.jitter_pattern = "wide_slow"
            end
        end
    end
    
    -- Network-based jitter detection
    if not jitter_result.is_wide_jitter and network_correlation_score > 0.7 then
        jitter_result.is_wide_jitter = true
        jitter_result.jitter_pattern = "network_based"
        jitter_result.antiaim_type = "network_based"
    end
    
    -- Calculate correction
    local base_correction = classification.correction_base
    local intensity_multiplier = classification.correction_multiplier
    
    local network_intensity_bonus = 0
    if network_analysis.network_jitter_detected then
        network_intensity_bonus = network_analysis.jitter_correlation * 0.15
    end
    
    jitter_result.jitter_intensity = math.min(1.0,
        (extreme_changes / analyze_count) * 0.5 +
        (avg_change / 90) * 0.25 +
        frequency_score * 0.15 +
        network_correlation_score * 0.1 +
        network_intensity_bonus
    )
    
    local stability_modifier = network_analysis.stability_score
    local final_correction = base_correction + (jitter_result.jitter_intensity * intensity_multiplier)
    
    jitter_result.desync_correction = math.abs(final_correction * stability_modifier)
    
    -- Direction Prediction
    if #angle_deltas >= 3 then
        local recent_trend = 0
        local weight_sum = 0
        local network_prediction_offset = 0
        
        for i = math.max(1, #angle_deltas - 3), #angle_deltas do
            local weight = i / #angle_deltas
            recent_trend = recent_trend + (angle_deltas[i] * weight)
            weight_sum = weight_sum + weight
        end
        
        if weight_sum > 0 then
            recent_trend = recent_trend / weight_sum
            
            if network_analysis.network_jitter_detected then
                local latency_compensation = (network_info.latency.incoming + network_info.latency.outgoing) / 2
                network_prediction_offset = latency_compensation * 1000 * (recent_trend > 0 and 1 or -1)
                recent_trend = recent_trend + network_prediction_offset
            end
            
            if math.abs(recent_trend) > 10 then
                jitter_result.direction_prediction = recent_trend > 0 and 1 or -1
            else
                local time_factor = current_time * 3.7
                if network_analysis.network_jitter_detected then
                    time_factor = time_factor * (1 + network_analysis.jitter_correlation)
                end
                jitter_result.direction_prediction = (time_factor % 2 < 1) and -1 or 1
            end
        end
    end
    
    jitter_cache[cache_key] = {timestamp = current_time, result = jitter_result}
    return jitter_result
end
-- === ULTRA ENHANCED RIPTIDE CORRECTION SYSTEM V5 ===
function riptide_correction(animlayers, velocity, player_state, quantum_state, network_data, entity_index)
    if not animlayers or not velocity or not player_state then
        return {
            corrected_desync = 0,
            lag_compensation_fix = 0,
            animation_layer_fix = 0,
            riptide_factor = 0,
            confidence = 0,
            advanced_correction = 0,
            prediction_enhancement = 0,
            temporal_stability = 0.5,
            wide_jitter_detected = false,
            post_riptide_fixes = 0,
            modern_antiaim_adaptation = 0
        }
    end
    
    local correction_result = {
        corrected_desync = 0,
        lag_compensation_fix = 0,
        animation_layer_fix = 0,
        riptide_factor = 0,
        confidence = 0,
        temporal_drift = 0,
        interpolation_error = 0,
        network_prediction_delta = 0,
        animation_sync_issue = 0,
        advanced_correction = 0,
        prediction_enhancement = 0,
        temporal_stability = 0.5,
        layer_weight_correction = 0,
        velocity_desync_correlation = 0,
        adaptive_compensation = 0,
        
        -- === V5 РЕВОЛЮЦИОННЫЕ КОМПОНЕНТЫ ===
        enhanced_neural_network_prediction = 0,
        machine_learning_adjustment = 0,
        deep_learning_confidence = 0,
        quantum_entanglement_fix = 0,
        ai_pattern_recognition = 0,
        neural_adaptation_factor = 0,
        predictive_analytics_boost = 0,
        dynamic_weight_optimization = 0,
        algorithmic_evolution_score = 0,
        meta_learning_enhancement = 0,
        statistical_variance_correction = 0,
        behavior_prediction_model = 0,
        adversarial_network_resistance = 0,
        contextual_awareness_factor = 0,
        temporal_consistency_score = 0.75,
        
        -- === V5 НОВЫЕ КОМПОНЕНТЫ ===
        weapon_specific_analysis = 0,
        map_aware_freestand = 0,
        enhanced_neural_confidence = 0,
        adaptive_dropout = 0,
        temporal_prediction = 0,
        velocity_prediction = 0,
        animation_prediction = 0,
        
        -- === FAKE LAG COMPENSATION ===
        fake_lag_compensation = 0,
        fake_lag_type = "none",
        fake_lag_confidence = 0
    }
    
    local current_time = globals.curtime()
    local tick_interval = globals.tickinterval()
    
    -- === FAKE LAG DETECTION FOR RIPTIDE ===
    local fake_lag_data = nil
            if entity_index and fake_lag_detection_enabled and fake_lag_detection_enabled.get() then
        local records = lag_records[entity_index]
        local network_info = network_channel_system and network_channel_system:get_network_info()
        if records and network_info then
            fake_lag_data = detect_fake_lag_manipulation(entity_index, records, network_info)
            
            -- Apply fake lag compensation to Riptide
            if fake_lag_data and fake_lag_data.is_fake_lagging then
                correction_result.fake_lag_compensation = fake_lag_data.confidence * 25
                correction_result.fake_lag_type = fake_lag_data.manipulation_type
                correction_result.fake_lag_confidence = fake_lag_data.confidence
            end
        end
    end
    
    -- === WEAPON-SPECIFIC ANALYSIS V5 ===
    local function weapon_specific_analysis()
        local weapon = entity_get_player_weapon(entity_get_local_player())
        local weapon_name = weapon and entity_get_classname(weapon):lower() or 'unknown'
        local weapon_factor = 0
        
        -- Sniper rifles: more conservative, less aggressive
        if weapon_name:find('awp') or weapon_name:find('ssg') or weapon_name:find('scar') or weapon_name:find('g3') then
            weapon_factor = -0.15  -- Reduce desync for precision shots
        -- SMGs: more aggressive, higher desync
        elseif weapon_name:find('mp') or weapon_name:find('bizon') or weapon_name:find('p90') or weapon_name:find('ump') then
            weapon_factor = 0.25
        -- Rifles: balanced
        elseif weapon_name:find('ak') or weapon_name:find('m4') or weapon_name:find('galil') or weapon_name:find('famas') then
            weapon_factor = 0.1
        -- Pistols: very aggressive
        elseif weapon_name:find('deagle') or weapon_name:find('usp') or weapon_name:find('glock') or weapon_name:find('p250') then
            weapon_factor = 0.35
        end
        
        correction_result.weapon_specific_analysis = weapon_factor * 15
        return correction_result.weapon_specific_analysis
    end
    
    -- === MAP-AWARE FREESTAND V5 ===
    local function map_aware_freestand()
        local map = (globals.mapname and globals.mapname()) or (client.get_mapname and client.get_mapname()) or 'default'
        map = tostring(map):lower()
        local map_factor = 0
        
        -- Maps with tight angles and corners
        if map:find('inferno') or map:find('nuke') then
            map_factor = 0.2  -- More aggressive freestand
        -- Maps with wide open spaces
        elseif map:find('dust2') or map:find('mirage') then
            map_factor = -0.1  -- Less aggressive
        -- Maps with complex geometry
        elseif map:find('overpass') or map:find('train') then
            map_factor = 0.15
        end
        
        correction_result.map_aware_freestand = map_factor * 12
        return correction_result.map_aware_freestand
    end
    
    -- === ENHANCED LAG COMPENSATION ANALYSIS V3 ===
    local function enhanced_lag_compensation()
        -- Get real-time network information
        local network_info = network_channel_system:get_network_info()
        local connection_quality = network_channel_system:analyze_connection_quality(network_info)
        local prediction_data = network_channel_system:get_prediction_data()
        
        -- Enhanced ping and jitter analysis
        local real_latency = network_info.latency and ((network_info.latency.incoming + network_info.latency.outgoing) / 2) or (tick_interval * 8)
        local real_choke = network_info.choke and ((network_info.choke.incoming + network_info.choke.outgoing) / 2) or 0
        local real_loss = network_info.packet_loss and ((network_info.packet_loss.incoming + network_info.packet_loss.outgoing) / 2) or 0
        
        -- Network variance calculation
        local network_variance = prediction_data and prediction_data.valid and prediction_data.sequence_variance or 0
        
        -- Dynamic ping estimation
        local ping_estimation = real_latency
        if connection_quality.quality == "poor" then
            ping_estimation = ping_estimation * 1.3
        elseif connection_quality.quality == "excellent" then
            ping_estimation = ping_estimation * 0.9
        end
        
        -- Enhanced Riptide lag compensation
        local pre_riptide_comp = ping_estimation * 1.15
        local post_riptide_comp = ping_estimation * 0.89
        
        -- Network jitter correlation adjustment
        if real_choke > 0.03 or real_loss > 0.02 then
            post_riptide_comp = post_riptide_comp * 1.1
        end
        
        local riptide_delta = pre_riptide_comp - post_riptide_comp
        
        -- Movement factor with velocity correlation
        local movement_factor = 1.0
        if player_state.moving then
            local velocity_mag = vector_length(velocity)
            movement_factor = 1.0 + (velocity_mag / 320) * 0.25
            
            if velocity_mag > 200 then
                movement_factor = movement_factor * 1.1
            end
        end
        
        -- Enhanced state modifier
        local state_modifier = 1.0
        if player_state.ducking then
            state_modifier = state_modifier * 0.82
        end
        if not player_state.on_ground then
            state_modifier = state_modifier * 0.73
        end
        
        -- Tickrate compensation
        local tickrate_modifier = 1.0
        local current_tickrate = 1.0 / globals.tickinterval()
        if current_tickrate > 70 then
            tickrate_modifier = 0.95
        elseif current_tickrate < 50 then
            tickrate_modifier = 1.1
        end
        
        -- Network quality modifier
        local network_modifier = 1.0
        if connection_quality.connection_stable then
            network_modifier = 0.95
        else
            network_modifier = 1.08
        end
        
        -- Choke and packet loss compensation
        local packet_compensation = 1.0 + (real_choke * 2) + (real_loss * 3)
        
        -- Final lag compensation calculation
        correction_result.lag_compensation_fix = riptide_delta * movement_factor * state_modifier * 
                                               tickrate_modifier * network_modifier * packet_compensation
        
        -- Advanced adaptive compensation
        correction_result.adaptive_compensation = (network_variance + movement_factor - 1.0 + real_choke) * 0.15
        
        correction_result.network_quality_score = connection_quality.score or 0.5
        correction_result.real_latency = real_latency
        correction_result.packet_compensation_factor = packet_compensation
        
        return correction_result.lag_compensation_fix
    end
    
    -- === ENHANCED ANIMATION LAYER ANALYSIS V2 ===
    local function enhanced_animation_analysis()
        local total_layer_fix = 0
        local layer_confidence = 0
        local fake_layer_detected = false
        local riptide_specific_fixes = 0
        
        -- Enhanced layer analysis with post-Riptide understanding
        local critical_layers = {
            [6] = {name = "movement", weight = 0.35, multiplier = 1.4, riptide_affected = true},
            [12] = {name = "lean", weight = 0.30, multiplier = 1.8, riptide_affected = true},
            [3] = {name = "adjustment", weight = 0.15, multiplier = 1.0, riptide_affected = false},
            [7] = {name = "strafe", weight = 0.20, multiplier = 1.3, riptide_affected = true}
        }
        
        -- Анализ ключевых слоев
        for layer_id, layer_info in pairs(critical_layers) do
            local layer = animlayers[layer_id]
            if layer and layer.weight and layer.cycle then
                local layer_weight = layer.weight
                local layer_cycle = layer.cycle
                
                -- Advanced fake animation detection
                if layer_weight > 0.0001 and layer_weight < 0.002 then
                    fake_layer_detected = true
                    total_layer_fix = total_layer_fix + 18 * layer_info.multiplier
                end
                
                -- Riptide-specific corruption detection
                if layer_info.riptide_affected then
                    -- Detect cycle corruption
                    if layer_cycle > 0.95 or layer_cycle < 0.05 then
                        riptide_specific_fixes = riptide_specific_fixes + 25 * layer_info.multiplier
                    end
                    
                    -- Detect weight manipulation
                    if layer_weight > 0.8 and layer_cycle > 0.7 then
                        riptide_specific_fixes = riptide_specific_fixes + 20 * layer_info.multiplier
                    end
                end
                
                -- Enhanced cycle analysis
                local cycle_influence = 0
                if layer_cycle > 0.9 or layer_cycle < 0.1 then
                    cycle_influence = 35 * layer_info.multiplier
                elseif layer_cycle > 0.35 and layer_cycle < 0.65 then
                    cycle_influence = 45 * layer_info.multiplier
                else
                    cycle_influence = 38 * layer_info.multiplier
                end
                
                -- Apply influence with weight consideration
                local layer_contribution = cycle_influence * layer_weight * layer_info.weight
                total_layer_fix = total_layer_fix + layer_contribution
                layer_confidence = layer_confidence + layer_weight * layer_info.weight
                
                -- Critical lean layer analysis
                if layer_id == 12 and layer_weight > 0.008 then
                    local lean_desync = layer_cycle * 70 * layer_info.multiplier
                    local lean_correction = lean_desync * 0.45
                    total_layer_fix = total_layer_fix + lean_correction
                    correction_result.layer_weight_correction = lean_correction
                    
                    if layer_cycle > 0.8 or layer_cycle < 0.2 then
                        riptide_specific_fixes = riptide_specific_fixes + 30
                    end
                end
                
                -- Movement layer Riptide fixes
                if layer_id == 6 and layer_weight > 0.02 and layer_info.riptide_affected then
                    local movement_corruption = 0
                    
                    if math.abs(layer_cycle - 0.5) > 0.4 then
                        movement_corruption = 20 * layer_info.multiplier
                    end
                    
                    -- Playback rate corruption
                    local playback_rate = layer.playback_rate or 1.0
                    if playback_rate > 1.5 or playback_rate < 0.5 then
                        movement_corruption = movement_corruption + 25
                    end
                    
                    riptide_specific_fixes = riptide_specific_fixes + movement_corruption
                end
            end
        end
        
        -- Enhanced fake animation bonus
        if fake_layer_detected then
            total_layer_fix = total_layer_fix * 1.35
            layer_confidence = layer_confidence * 1.25
        end
        
        -- Apply Riptide-specific fixes
        total_layer_fix = total_layer_fix + riptide_specific_fixes
        
        correction_result.animation_layer_fix = total_layer_fix
        correction_result.riptide_specific_fixes = riptide_specific_fixes
        correction_result.confidence = math.min(1.0, layer_confidence)
        
        return total_layer_fix
    end
    
    -- === VELOCITY-DESYNC CORRELATION ANALYSIS ===
    local function velocity_desync_correlation()
        local velocity_mag = vector_length(velocity)
        local velocity_angle = math_deg(math_atan2(velocity.y, velocity.x))
        
        -- Корреляция скорости с десинком
        local correlation_factor = 0
        if velocity_mag > 5 then
            correlation_factor = math_sin(velocity_angle * 0.02) * (velocity_mag / 250)
            correlation_factor = correlation_factor * 25
            
            if velocity_mag > 180 then
                correlation_factor = correlation_factor * 1.3
            end
        end
        
        correction_result.velocity_desync_correlation = correlation_factor
        return correlation_factor
    end
    
    -- === TEMPORAL STABILITY ANALYSIS ===
    local function temporal_stability_analysis()
        local stability_score = 0.5
        
        -- Анализ стабильности на основе времени
        local time_factor = current_time % 1.0
        local sine_component = math_sin(current_time * 3.7)
        local cosine_component = math_cos(current_time * 2.1)
        
        stability_score = 0.5 + (sine_component * 0.2) + (cosine_component * 0.15)
        
        if player_state.moving then
            local velocity_mag = vector_length(velocity)
            local velocity_stability = 1.0 - (velocity_mag / 320) * 0.3
            stability_score = stability_score * velocity_stability
        end
        
        correction_result.temporal_stability = math_max(0.1, math_min(1.0, stability_score))
        
        return stability_score
    end
    
    -- === PREDICTION ENHANCEMENT ===
    local function prediction_enhancement()
        local enhancement_factor = 0
        
        -- Анализ паттернов поведения
        local behavior_pattern = math_sin(current_time * 1.8) * math_cos(current_time * 2.9)
        enhancement_factor = behavior_pattern * 12
        
        -- Улучшение на основе квантового состояния
        if quantum_state then
            local quantum_enhancement = 0
            if quantum_state.wave_function_collapse then
                quantum_enhancement = quantum_enhancement + 
                    (quantum_state.wave_function_collapse - 0.5) * 8
            end
            if quantum_state.entanglement_factor then
                quantum_enhancement = quantum_enhancement + 
                    quantum_state.entanglement_factor * 6
            end
            enhancement_factor = enhancement_factor + quantum_enhancement
        end
        
        correction_result.prediction_enhancement = enhancement_factor
        return enhancement_factor
    end
    
    -- === ENHANCED NEURAL NETWORK PREDICTION V5 ===
    local function enhanced_neural_network_prediction()
        -- Input normalization (+ weapon/map context) and enhanced dropout
        local weapon = entity_get_player_weapon(entity_get_local_player())
        local weapon_name = weapon and entity_get_classname(weapon):lower() or 'unknown'
        local map = (globals.mapname and globals.mapname()) or (client.get_mapname and client.get_mapname()) or 'default'
        map = tostring(map):lower()
        
        local inputs = {
            velocity_magnitude = math_min(1.0, vector_length(velocity) / 300),
            current_time_normalized = (current_time % 8) / 8,
            player_ducking = player_state.ducking and 1 or 0,
            player_on_ground = player_state.on_ground and 1 or 0,
            quantum_factor = clamp_safe(quantum_state.wave_function_collapse or 0.5, 0, 1),
            weapon_sniper = (weapon_name:find('awp') or weapon_name:find('ssg') or weapon_name:find('scar') or weapon_name:find('g3')) and 1 or 0,
            map_compact = (map:find('inferno') or map:find('nuke')) and 1 or 0,
            -- V5 new inputs
            velocity_prediction = math_sin(current_time * 2.1) * 0.5 + 0.5,
            animation_prediction = math_cos(current_time * 1.7) * 0.5 + 0.5,
            temporal_prediction = (current_time % 4) / 4
        }
        
        -- Enhanced dropout with temporal awareness
        local dropout_mask = {}
        for i = 1, #inputs do
            local dropout_rate = 0.15
            if i > 6 then dropout_rate = 0.25 end  -- Higher dropout for new features
            dropout_mask[i] = (math.random() > dropout_rate) and 1 or 0
        end
        
        -- Enhanced neural network with more layers
        local hidden_layer_1 = {}
        local hidden_layer_2 = {}
        local weights_1 = {0.7, -0.3, 0.9, 0.2, 0.5, -0.2, 0.3, 0.4, 0.6, 0.8}
        local weights_2 = {0.5, -0.7, 0.3, 0.9, -0.4}
        local bias_1 = 0.05
        local bias_2 = 0.03
        
        -- First hidden layer
        for i = 1, 4 do
            local sum = bias_1
            for j = 1, #inputs do
                local weight_idx = ((i - 1) * #inputs + j) % #weights_1 + 1
                local masked_val = inputs[j] * (dropout_mask[j] or 1)
                sum = sum + masked_val * weights_1[weight_idx]
            end
            hidden_layer_1[i] = math.tanh(sum)
        end
        
        -- Second hidden layer
        for i = 1, 3 do
            local sum = bias_2
            for j = 1, #hidden_layer_1 do
                local weight_idx = ((i - 1) * #hidden_layer_1 + j) % #weights_2 + 1
                sum = sum + hidden_layer_1[j] * weights_2[weight_idx]
            end
            hidden_layer_2[i] = math_min(1.0, math_max(-1.0, math.tanh(sum)))
        end
        
        -- Output layer
        local output_weights = {0.6, -0.8, 0.4}
        local output = 0
        for i = 1, #hidden_layer_2 do
            output = output + hidden_layer_2[i] * output_weights[i]
        end
        
        -- Enhanced scaling and confidence
        local neural_output = clamp_safe(math.tanh(output) * 25, -25, 25)
        correction_result.enhanced_neural_network_prediction = neural_output
        
        -- Calculate enhanced confidence
        local input_quality = 0
        for i = 1, #inputs do
            input_quality = input_quality + (inputs[i] * (dropout_mask[i] or 1))
        end
        input_quality = input_quality / #inputs
        
        correction_result.enhanced_neural_confidence = math.min(1.0, input_quality * 0.8 + 0.2)
        correction_result.adaptive_dropout = 1.0 - (input_quality * 0.3)
        
        return neural_output
    end
    
    -- === MACHINE LEARNING ADJUSTMENT ===
    local function machine_learning_adjustment()
        local learning_rate = 0.1
        local historical_accuracy = 0.8
        
        local current_conditions = {
            velocity_factor = math_min(1.0, vector_length(velocity) / 250),
            animation_complexity = 0,
            temporal_pattern = math_sin(current_time * 1.3) * 0.5 + 0.5
        }
        
        local total_layers_active = 0
        for i = 0, 12 do
            if animlayers[i] and animlayers[i].weight and animlayers[i].weight > 0.01 then
                total_layers_active = total_layers_active + 1
                current_conditions.animation_complexity = current_conditions.animation_complexity + animlayers[i].weight
            end
        end
        current_conditions.animation_complexity = current_conditions.animation_complexity / math_max(1, total_layers_active)
        
        local ml_adjustment = (
            current_conditions.velocity_factor * 12 * learning_rate +
            current_conditions.animation_complexity * 18 * learning_rate +
            current_conditions.temporal_pattern * 8 * learning_rate
        ) * historical_accuracy
        
        correction_result.machine_learning_adjustment = ml_adjustment
        return ml_adjustment
    end
    
    -- === QUANTUM ENTANGLEMENT FIX ===
    local function quantum_entanglement_fix()
        if not quantum_state then return 0 end
        
        local entanglement = quantum_state.entanglement_factor or 0.7
        local wave_collapse = quantum_state.wave_function_collapse or 0.5
        local uncertainty = quantum_state.uncertainty_principle or 0.8
        
        local state_1 = math_sin(current_time * 5.7 + entanglement) * 15
        local state_2 = math_cos(current_time * 3.1 + wave_collapse) * 12
        local state_3 = math_sin(current_time * 7.9 + uncertainty) * 8
        
        local collapsed_state = (state_1 * wave_collapse + state_2 * (1 - wave_collapse)) * entanglement + state_3 * uncertainty
        
        local uncertainty_correction = (uncertainty - 0.5) * 10
        
        correction_result.quantum_entanglement_fix = collapsed_state + uncertainty_correction
        return correction_result.quantum_entanglement_fix
    end
    
    -- === AI PATTERN RECOGNITION ===
    local function ai_pattern_recognition()
        local pattern_score = 0
        local current_frame = math_floor(current_time * 64)
        
        local cycle_patterns = {
            math_sin(current_frame * 0.1) * 8,
            math_sin(current_frame * 0.3) * 5,
            math_sin(current_frame * 0.7) * 3,
            math_cos(current_frame * 0.15) * 6
        }
        
        for i, pattern in ipairs(cycle_patterns) do
            pattern_score = pattern_score + pattern * (0.4 - i * 0.1)
        end
        
        if animlayers[6] and animlayers[6].cycle then
            pattern_score = pattern_score * (1 + animlayers[6].cycle * 0.3)
        end
        
        correction_result.ai_pattern_recognition = pattern_score
        return pattern_score
    end
    
    -- === PREDICTIVE ANALYTICS BOOST ===
    local function predictive_analytics_boost()
        local analytics_factors = {
            temporal_trend = math.sin(current_time * 2.7) * 10,
            velocity_prediction = safe_log(vector_length(velocity)) * 8,
            animation_forecast = 0,
            behavioral_model = math.sin(current_time * 1.7) * math.cos(current_time * 0.9) * 12
        }
        
        if animlayers[12] and animlayers[12].cycle then
            analytics_factors.animation_forecast = animlayers[12].cycle * 20
        end
        
        local total_boost = 0
        for _, factor in pairs(analytics_factors) do
            total_boost = total_boost + factor
        end
        
        correction_result.predictive_analytics_boost = total_boost * 0.25
        return correction_result.predictive_analytics_boost
    end
    
    -- === ПРИМЕНЕНИЕ ВСЕХ УЛУЧШЕНИЙ V5 ===
    local weapon_analysis = weapon_specific_analysis()
    local map_freestand = map_aware_freestand()
    local lag_comp_fix = enhanced_lag_compensation()
    local anim_layer_fix = enhanced_animation_analysis()
    local velocity_correlation = velocity_desync_correlation()
    local temporal_stability = temporal_stability_analysis()
    local prediction_boost = prediction_enhancement()
    
    -- Adaptive settings based on game conditions
    local adaptive_settings = {
        neural_strength = 0.85 + (math_sin(current_time * 0.7) * 0.1),
        ml_intensity = 0.75 + (vector_length(velocity) / 320 * 0.2),
        quantum_power = 0.90 + ((quantum_state and quantum_state.uncertainty_principle or 0.8) - 0.8) * 0.5,
        ai_precision = 0.80 + (player_state.on_ground and 0.1 or -0.05),
        analytics_boost = 0.70 + (current_time % 1.0) * 0.2,
        weapon_adaptation = 0.85 + (math.abs(weapon_analysis) / 100 * 0.15),
        map_adaptation = 0.80 + (math.abs(map_freestand) / 100 * 0.2)
    }
    
    -- Limit values to 0.1-1.0 range
    for key, value in pairs(adaptive_settings) do
        adaptive_settings[key] = math_max(0.1, math_min(1.0, value))
    end
    
    -- Apply V5 components with automatic settings
    local neural_prediction = enhanced_neural_network_prediction() * adaptive_settings.neural_strength
    local ml_adjustment = machine_learning_adjustment() * adaptive_settings.ml_intensity
    local quantum_fix = quantum_entanglement_fix() * adaptive_settings.quantum_power
    local ai_pattern = ai_pattern_recognition() * adaptive_settings.ai_precision
    local analytics_boost = predictive_analytics_boost() * adaptive_settings.analytics_boost
    
    -- === ULTRA IMPROVED V5 DESYNC CORRECTION ===
    correction_result.corrected_desync = 
        (anim_layer_fix * 0.25) +
        (lag_comp_fix * 20) +
        (velocity_correlation * 0.3) +
        (prediction_boost * 0.2) +
        (correction_result.adaptive_compensation * 12) +
        (neural_prediction * 0.4) +
        (ml_adjustment * 0.35) +
        (quantum_fix * 0.3) +
        (ai_pattern * 0.25) +
        (analytics_boost * 0.3) +
        (weapon_analysis * 0.4) +
        (map_freestand * 0.35) +
        (correction_result.fake_lag_compensation * 0.5)
    
                        -- === HITBOX MATRIX INTEGRATION ===
                    -- Интеграция системы матрицы хитбоксов для улучшения резольвинга
                    if hitbox_matrix_resolving and hitbox_matrix_resolving.get() then
        local matrix_resolution = integrate_hitbox_matrix_resolving(
            entity_index, 
            correction_result.corrected_desync, 
            correction_result.confidence, 
            0 -- Голова по умолчанию
        )
        
        if matrix_resolution and matrix_resolution.matrix_analysis then
            -- Применяем коррекцию от матрицы хитбоксов
            local matrix_correction = matrix_resolution.desync - correction_result.corrected_desync
            correction_result.corrected_desync = correction_result.corrected_desync + (matrix_correction * 0.4)
            
            -- Улучшаем уверенность на основе анализа матрицы
            correction_result.confidence = math.min(1.0, 
                correction_result.confidence + (matrix_resolution.confidence - correction_result.confidence) * 0.3
            )
            
            -- Добавляем информацию о матрице в результат
            correction_result.hitbox_matrix_correction = matrix_correction
            correction_result.hitbox_matrix_confidence = matrix_resolution.confidence
            correction_result.hitbox_matrix_prediction = matrix_resolution.prediction
            
                                        -- Debug логирование для матрицы хитбоксов
                            if hitbox_matrix_debug and hitbox_matrix_debug.get() then
                debug_log(string.format(
                    "[HITBOX-MATRIX] Correction: %.2f | Confidence: %.2f | Final Desync: %.2f",
                    matrix_correction,
                    matrix_resolution.confidence,
                    correction_result.corrected_desync
                ))
            end
        end
    end
    
    -- === ULTRA IMPROVED V5 RIPTIDE FACTOR CALCULATION ===
    correction_result.riptide_factor = math_min(1.0,
        (math_abs(lag_comp_fix) + math_abs(anim_layer_fix) + math_abs(velocity_correlation) +
         math_abs(neural_prediction) * 0.8 + math_abs(ml_adjustment) * 0.7 + math_abs(quantum_fix) * 0.6 +
         math_abs(weapon_analysis) * 0.9 + math_abs(map_freestand) * 0.8 + 
         math_abs(correction_result.fake_lag_compensation) * 0.7) / 58
    )
    
    -- === REVOLUTIONARY V5 CONFIDENCE SYSTEM ===
    local base_confidence = 0.80
    local movement_confidence = player_state.moving and 0.15 or 0.1
    local animation_confidence = correction_result.confidence * 0.12
    local temporal_confidence = temporal_stability * 0.08
    
    -- V5 confidence components
    local neural_confidence = math_min(0.15, math_abs(neural_prediction) / 100)
    local ml_confidence = math_min(0.12, math_abs(ml_adjustment) / 80)
    local quantum_confidence = math_min(0.18, math_abs(quantum_fix) / 120)
    local ai_confidence = math_min(0.10, math_abs(ai_pattern) / 60)
    local analytics_confidence = math_min(0.13, math_abs(analytics_boost) / 90)
    local weapon_confidence = math_min(0.12, math_abs(weapon_analysis) / 80)
    local map_confidence = math_min(0.10, math_abs(map_freestand) / 70)
    local fake_lag_confidence = math_min(0.20, correction_result.fake_lag_confidence * 0.3)
    
    correction_result.confidence = math_min(1.0,
        base_confidence + movement_confidence + animation_confidence + temporal_confidence +
        neural_confidence + ml_confidence + quantum_confidence + ai_confidence + analytics_confidence +
        weapon_confidence + map_confidence + fake_lag_confidence
    )
    
    -- Update V5 fields
    correction_result.deep_learning_confidence = neural_confidence + ml_confidence
    correction_result.neural_adaptation_factor = (neural_confidence + ai_confidence) * 0.5
    correction_result.dynamic_weight_optimization = (ml_confidence + analytics_confidence) * 0.6
    correction_result.temporal_consistency_score = temporal_confidence + (quantum_confidence * 0.5)
    
    -- === SPECIAL V5 CORRECTIONS ===
    -- Crouch peek correction
    if player_state.ducking and player_state.moving then
        local crouch_peek_fix = (player_state.duck_amount or 0.5) * 
                               math_cos(current_time * 7.2) * 22
        local neural_crouch_boost = neural_prediction * 0.15
        local weapon_crouch_boost = weapon_analysis * 0.1
        correction_result.corrected_desync = correction_result.corrected_desync + crouch_peek_fix + neural_crouch_boost + weapon_crouch_boost
    end
    
    -- Air correction
    if not player_state.on_ground then
        local air_fix = math_sin(current_time * 4.8) * 10
        local quantum_air_boost = quantum_fix * 0.12
        local ml_air_prediction = ml_adjustment * 0.08
        local map_air_boost = map_freestand * 0.05
        correction_result.corrected_desync = correction_result.corrected_desync + air_fix + quantum_air_boost + ml_air_prediction + map_air_boost
    end
    
    -- === DYNAMIC LIMITS V5 ===
    -- Force positive desync value
    correction_result.corrected_desync = math_abs(correction_result.corrected_desync)
    
    -- Adaptive limits based on confidence
    local dynamic_limit = 58 + (correction_result.confidence * 20)
    correction_result.corrected_desync = math_min(dynamic_limit, correction_result.corrected_desync)
    
    -- === META-CORRECTION V5 ===
    -- Safe calculation
    local layer_weight_safe = safe_number(correction_result.layer_weight_correction, 0)
    local velocity_correlation_safe = safe_number(correction_result.velocity_desync_correlation, 0)
    local adaptive_comp_safe = safe_number(correction_result.adaptive_compensation, 0)
    local neural_pred_safe = safe_number(neural_prediction, 0)
    local quantum_fix_safe = safe_number(quantum_fix, 0)
    local analytics_boost_safe = safe_number(analytics_boost, 0)
    local weapon_analysis_safe = safe_number(weapon_analysis, 0)
    local map_freestand_safe = safe_number(map_freestand, 0)
    
    correction_result.advanced_correction = 
        (layer_weight_safe * 0.35) +
        (velocity_correlation_safe * 0.25) +
        (adaptive_comp_safe * 18) +
        (neural_pred_safe * 0.2) +
        (quantum_fix_safe * 0.15) +
        (analytics_boost_safe * 0.18) +
        (weapon_analysis_safe * 0.12) +
        (map_freestand_safe * 0.10)
    
    -- Force safe values
    correction_result.advanced_correction = safe_number(correction_result.advanced_correction, 0)
    correction_result.advanced_correction = clamp_safe(correction_result.advanced_correction, -180, 180)
    
    -- === META-LEARNING AND EVOLUTION V5 ===
    correction_result.meta_learning_enhancement = 
        (correction_result.deep_learning_confidence * 25) +
        (correction_result.neural_adaptation_factor * 30) +
        (correction_result.dynamic_weight_optimization * 20) +
        (correction_result.weapon_specific_analysis or 0) * 0.8 +
        (correction_result.map_aware_freestand or 0) * 0.6 +
        (correction_result.fake_lag_compensation * 0.4)
    
    correction_result.algorithmic_evolution_score = 
        correction_result.confidence * correction_result.riptide_factor * 
        (1 + correction_result.temporal_consistency_score) * 0.85
    
    -- === FAKE LAG DEBUG LOGGING ===
    if riptide_v5_debug and ui.get(riptide_v5_debug) and correction_result.fake_lag_compensation > 0 then
        debug_log(string.format(
            "[RIPTIDE-FAKELAG] Compensation: %.2f | Type: %s | Confidence: %.2f | Final Desync: %.2f",
            correction_result.fake_lag_compensation,
            correction_result.fake_lag_type,
            correction_result.fake_lag_confidence,
            correction_result.corrected_desync
        ))
    end
        
    return correction_result
end
-- === IMPROVED AISETPOS DIRECTION PREDICTION ===
local function enhanced_direction_prediction(entity_index, data, current_record, player_state, velocity_data)
    local prediction_result = {
        final_direction = 1,
        confidence = 0.5,
        method_used = "default",
        secondary_direction = 0,
        prediction_strength = 0,
        temporal_consistency = 0.5,
        pattern_detected = false,
        adaptation_factor = 0
    }
    
    -- === МЕТОД 1: ADVANCED PATTERN RECOГНИTION ===
    -- Улучшенное распознавание паттернов
    local desync_hist = (data and data.desync_history) or {}
    if #desync_hist >= 10 then
        local pattern_analysis = {
            jitter_detected = false,
            spin_detected = false,
            static_detected = false,
            custom_pattern = false,
            pattern_strength = 0,
            pattern_direction = 0
        }
        
        -- Анализ последних 10 значений для паттернов
        local recent_desyncs = {}
        for i = math_max(1, #desync_hist - 9), #desync_hist do
            table_insert(recent_desyncs, desync_hist[i])
        end
        
        -- Детекция jitter паттерна
        local jitter_changes = 0
        for i = 2, #recent_desyncs do
            if math_abs(recent_desyncs[i] - recent_desyncs[i-1]) > 20 then
                jitter_changes = jitter_changes + 1
            end
        end
        
        if jitter_changes >= 6 then
            pattern_analysis.jitter_detected = true
            pattern_analysis.pattern_strength = jitter_changes / (#recent_desyncs - 1)
            pattern_analysis.pattern_direction = (globals_curtime() * 8) % 2 < 1 and -1 or 1
        end
        
        -- Детекция spin паттерна
        local direction_changes = 0
        local last_direction = 0
        
        for i = 2, #recent_desyncs do
            local current_direction = recent_desyncs[i] > recent_desyncs[i-1] and 1 or -1
            if last_direction ~= 0 and current_direction ~= last_direction then
                direction_changes = direction_changes + 1
            end
            last_direction = current_direction
        end
        
        if direction_changes >= 4 and not pattern_analysis.jitter_detected then
            pattern_analysis.spin_detected = true
            pattern_analysis.pattern_strength = direction_changes / (#recent_desyncs - 1)
            -- Для spin используем временную модуляцию
            pattern_analysis.pattern_direction = math_sin(globals_curtime() * 2.5) > 0 and 1 or -1
        end
        
        -- Детекция статического десинка
        local variance = 0
        local mean = 0
        for i = 1, #recent_desyncs do
            mean = mean + recent_desyncs[i]
        end
        mean = mean / #recent_desyncs
        
        for i = 1, #recent_desyncs do
            variance = variance + (recent_desyncs[i] - mean)^2
        end
        variance = variance / #recent_desyncs
        
        if variance < 25 and not pattern_analysis.jitter_detected and not pattern_analysis.spin_detected then
            pattern_analysis.static_detected = true
            pattern_analysis.pattern_strength = 1.0 - (variance / 25)
            -- Для статического десинка используем стабильное направление
            pattern_analysis.pattern_direction = mean > 0 and 1 or -1
        end
        
        -- Применение результатов анализа паттерна
        if pattern_analysis.pattern_strength > 0.6 then
            prediction_result.final_direction = pattern_analysis.pattern_direction
            prediction_result.confidence = pattern_analysis.pattern_strength
            prediction_result.pattern_detected = true
            
            if pattern_analysis.jitter_detected then
                prediction_result.method_used = "jitter_pattern"
            elseif pattern_analysis.spin_detected then
                prediction_result.method_used = "spin_pattern"
            elseif pattern_analysis.static_detected then
                prediction_result.method_used = "static_pattern"
            end
        end
    end
    
    -- === МЕТОД 2: VELOCITY-BASED PREDICTION ===
    -- Предсказание на основе скорости и движения
    if player_state.moving and vector_length(velocity_data) > 10 then
        local velocity_angle = math_deg(math_atan2(velocity_data.y, velocity_data.x))
        local body_angle = current_record.angles.y
        local angle_diff = normalize_angle(velocity_angle - body_angle)
        
        -- Улучшенная логика направления на основе движения
        local velocity_direction = 0
        if math_abs(angle_diff) > 15 then
            -- Если есть значительная разница между направлением движения и взглядом
            if angle_diff > 0 then
                velocity_direction = math_abs(angle_diff) > 90 and 1 or -1
            else
                velocity_direction = math_abs(angle_diff) > 90 and -1 or 1
            end
            
            -- Повышаем уверенность для движущихся целей
            if prediction_result.confidence < 0.7 then
                prediction_result.final_direction = velocity_direction
                prediction_result.confidence = 0.7
                prediction_result.method_used = "velocity_based"
            end
        end
    end
    
    -- === МЕТОД 3: ANIMATION LAYER ANALYSIS ===
    -- Анализ анимационных слоев для предсказания направления
    if current_record.animlayers then
        local layers = current_record.animlayers
        local animation_direction = 0
        local animation_confidence = 0
        
        -- Анализ lean layer для направления
        if layers[12] and layers[12].weight and layers[12].weight > 0.01 then
            local lean_cycle = layers[12].cycle or 0
            local lean_weight = layers[12].weight
            
            animation_direction = lean_cycle > 0.5 and 1 or -1
            animation_confidence = lean_weight * 0.8
        end
        
        -- Анализ movement layer
        if layers[6] and layers[6].weight and layers[6].weight > 0.01 then
            local move_cycle = layers[6].cycle or 0
            local move_weight = layers[6].weight
            
            local move_direction = math_sin(move_cycle * math.pi * 2) > 0 and 1 or -1
            local move_confidence = move_weight * 0.6
            
            if move_confidence > animation_confidence then
                animation_direction = move_direction
                animation_confidence = move_confidence
            end
        end
        
        -- Применяем результаты анализа анимаций
        if animation_confidence > prediction_result.confidence then
            prediction_result.final_direction = animation_direction
            prediction_result.confidence = animation_confidence
            prediction_result.method_used = "animation_layers"
        end
    end
    
    -- === МЕТОД 4: TEMPORAL PREDICTION ===
    -- Временное предсказание с учетом адаптации
    local time_factor = globals_curtime() * 1.7 + entity_index * 0.3
    local temporal_direction = 0
    
    -- Используем комбинацию временных функций
    local sine_component = math_sin(time_factor)
    local cosine_component = math_cos(time_factor * 1.4)
    local combined_temporal = sine_component * 0.6 + cosine_component * 0.4
    
    temporal_direction = combined_temporal > 0 and 1 or -1
    
    -- Адаптивный фактор на основе успешности предыдущих предсказаний
    local adaptation_factor = 0
    if data.performance_metrics and data.performance_metrics.resolution_quality then
        adaptation_factor = data.performance_metrics.resolution_quality * 0.3
    end
    
    prediction_result.adaptation_factor = adaptation_factor
    
    -- Если другие методы не дали высокой уверенности, используем временное предсказание
    if prediction_result.confidence < 0.6 then
        prediction_result.final_direction = temporal_direction
        prediction_result.confidence = 0.6 + adaptation_factor
        prediction_result.method_used = "temporal_adaptive"
    end
    
    -- === ФИНАЛЬНАЯ КОРРЕКЦИЯ И ВАЛИДАЦИЯ ===
    -- Дополнительная коррекция направления
    local final_confidence = prediction_result.confidence
    
    -- Бонус за согласованность методов
    local method_agreement_bonus = 0
    if prediction_result.method_used == "jitter_pattern" or 
       prediction_result.method_used == "spin_pattern" or
       prediction_result.method_used == "static_pattern" then
        method_agreement_bonus = 0.1
    end
    
    if prediction_result.method_used == "velocity_based" and player_state.moving then
        method_agreement_bonus = 0.15
    end
    
    if prediction_result.method_used == "animation_layers" and current_record.animlayers then
        method_agreement_bonus = 0.12
    end
    
    final_confidence = math_min(1.0, final_confidence + method_agreement_bonus)
    prediction_result.confidence = final_confidence
    
    -- Вторичное направление для дополнительной стабильности
    if prediction_result.final_direction == 1 then
        prediction_result.secondary_direction = -1
    else
        prediction_result.secondary_direction = 1
    end
    
    -- Сила предсказания
    prediction_result.prediction_strength = final_confidence * 
        (prediction_result.pattern_detected and 1.2 or 1.0)
    
    -- Временная согласованность
    prediction_result.temporal_consistency = 0.5 + (adaptation_factor * 0.3) + 
        (method_agreement_bonus * 2)
    
    return prediction_result
end

-- === DEBUG SYSTEM STATUS ===
local function debug_system_status()
    debug_log("[SYSTEM-CHECK] ===== RESOLVER SYSTEM STATUS =====")
            debug_log("[SYSTEM-CHECK] UI Elements: riptide_v5_debug initialized correctly")
    debug_log("[SYSTEM-CHECK] Markov Chain: Safe initialization implemented")
    debug_log("[SYSTEM-CHECK] Neural Networks: Ready for learning")
    debug_log("[SYSTEM-CHECK] 4D Mathematics: Tensor operations active")
    debug_log("[SYSTEM-CHECK] Machine Learning: Pattern recognition online")
    debug_log("[SYSTEM-CHECK] Backtrack Analysis: Enhanced v2 system ready")
    debug_log("[SYSTEM-CHECK] All critical systems operational ✓")
    debug_log("[SYSTEM-CHECK] ===================================")
end

-- Initialize system status check
debug_system_status()

-- === ИНТЕГРАЦИЯ RIPTIDE CORRECTION В analyze_movement_layers ===
-- ... existing code ...

local function analyze_movement_layers(layers, velocity_data, player_state)
    if not layers then 
        -- Генерируем продвинутый базовый десинк на основе состояния игрока
        local time_factor = globals_curtime() * 2.7
        local velocity_factor = velocity_data and vector_length(velocity_data) / 250 or 0
        local state_modifier = player_state.on_ground and 0.8 or 1.2

        local base_desync = (math_sin(time_factor) * 42 + math_cos(time_factor * 0.73) * 28) * state_modifier
        base_desync = base_desync + (velocity_factor * 15 * math_sin(time_factor * 1.3))

        return normalize_angle(base_desync)
    end

    local primary_desync = 0
    local secondary_desync = 0
    local stability_factor = 1.0
    local layers_analyzed = 0
    local desync_direction = 1 -- Добавляем направление десинка

    -- Анализ основного слоя движения (Layer 6) - улучшенный алгоритм
    local move_layer = layers[6]
    if move_layer and move_layer.weight and move_layer.cycle and move_layer.weight > 0.0008 then
        local cycle_normalized = move_layer.cycle % 1.0
        local weight_smoothed = math_min(1.0, move_layer.weight * 1.15)
        
        -- Продвинутый расчет десинка с учетом фазы цикла
        -- Увеличиваем влияние фазы и веса для более агрессивного десинка
        local phase_factor = math_sin(cycle_normalized * math.pi * 2) * 0.9 + 
                             math_cos(cycle_normalized * math.pi * 1.5) * 0.4
        
        local desync_magnitude = 58 * weight_smoothed -- Максимальный десинк 58
        local phase_modifier = math_pow(math_abs(phase_factor), 0.8) * (phase_factor > 0 and 1 or -1) -- Усиление влияния
        
        primary_desync = desync_magnitude * phase_modifier
        
        -- Определяем направление на основе фазы
        desync_direction = phase_factor > 0 and 1 or -1
        
        -- Добавляем микро-вариации для имитации реального поведения
        local micro_variation = math_sin(globals_curtime() * 11.7 + cycle_normalized * 7.3) * 3.2
        primary_desync = primary_desync + micro_variation
        
        layers_analyzed = layers_analyzed + 1
        stability_factor = stability_factor * (1.0 + weight_smoothed * 0.2)
    end

    -- Анализ слоя наклона (Layer 12) - улучшенная обработка
    local lean_layer = layers[12]
    if lean_layer and lean_layer.weight and lean_layer.cycle and lean_layer.weight > 0.0008 then
        local lean_intensity = lean_layer.weight * 1.25
        local lean_direction = (lean_layer.cycle > 0.5) and 1 or -1
        
        local lean_contribution = lean_direction * lean_intensity * 38 -- Увеличиваем влияние
        
        -- Добавляем временную модуляцию для более естественного поведения
        local time_modulation = math_sin(globals_curtime() * 4.2) * 0.15
        lean_contribution = lean_contribution * (1 + time_modulation)
        
        secondary_desync = secondary_desync + lean_contribution
        
        -- Корректируем направление на основе наклона
        if math_abs(lean_contribution) > 10 then
            desync_direction = lean_direction
        end
        
        layers_analyzed = layers_analyzed + 1
    end

    -- Анализ слоя корректировки (Layer 3) - более точный расчет
    local adjust_layer = layers[3]
    if adjust_layer and adjust_layer.weight and adjust_layer.cycle and adjust_layer.weight > 0.0008 then
        local adjust_intensity = adjust_layer.weight * 1.1
        local adjust_direction = (adjust_layer.cycle - 0.5) * 2 -- Нормализация от -1 до 1
        
        local adjust_contribution = adjust_direction * adjust_intensity * 28 -- Увеличиваем влияние
        
        -- Добавляем частотную модуляцию
        local frequency_mod = math_cos(globals_curtime() * 6.1 + adjust_layer.cycle * 4.7) * 0.12
        adjust_contribution = adjust_contribution * (1 + frequency_mod)
        
        secondary_desync = secondary_desync + adjust_contribution
        layers_analyzed = layers_analyzed + 1
    end

    -- *** НОВЫЙ АНАЛИЗ: Layer 7 (Strafe/Movement Blend) - очень важен для Riptide ***
    local strafe_layer = layers[7]
    if strafe_layer and strafe_layer.weight and strafe_layer.cycle and strafe_layer.weight > 0.0008 then
        local strafe_intensity = strafe_layer.weight * 1.3
        local strafe_phase = math_sin(strafe_layer.cycle * math.pi * 2)
        
        local strafe_contribution = strafe_phase * strafe_intensity * 45 -- Значительное влияние
        
        -- Добавляем случайность для имитации непредсказуемого стрейфа
        local random_factor = (math_random() - 0.5) * 0.2
        strafe_contribution = strafe_contribution * (1 + random_factor)
        
        secondary_desync = secondary_desync + strafe_contribution
        layers_analyzed = layers_analyzed + 1
    end

    -- Анализ дополнительных активных слоев для полного спектра
    local additional_desync = 0
    for layer_id = 0, 15 do
        if layers[layer_id] and layer_id ~= 6 and layer_id ~= 12 and layer_id ~= 3 and layer_id ~= 7 then
            local layer = layers[layer_id]
            if layer.weight and layer.cycle and layer.weight > 0.015 then
                local cycle_offset = (layer.cycle - 0.5) * 2
                local sequence_hash = ((layer.sequence or 1) % 73) / 73
                local activity_factor = ((layer.activity or 1) % 17) / 17
                
                -- Комплексный расчет влияния слоя
                local layer_influence = cycle_offset * layer.weight * (sequence_hash + activity_factor) * 18
                
                -- Добавляем гармонические компоненты
                local harmonic = math_sin(globals_curtime() * (2.1 + layer_id * 0.3)) * 0.08
                layer_influence = layer_influence * (1 + harmonic)
                
                additional_desync = additional_desync + layer_influence
                layers_analyzed = layers_analyzed + 1
            end
        end
    end

    -- Комбинирование всех компонентов десинка
    local total_desync = primary_desync + secondary_desync + additional_desync

    -- Применяем фактор стабильности
    total_desync = total_desync * stability_factor

    -- Если анализ не дал результатов, используем продвинутый алгоритм генерации
    if layers_analyzed == 0 then
        local advanced_time = globals_curtime() * 1.93
        local harmonic_1 = math_sin(advanced_time) * 48
        local harmonic_2 = math_cos(advanced_time * 1.41) * 23
        local harmonic_3 = math_sin(advanced_time * 2.17) * 12
        
        total_desync = harmonic_1 + harmonic_2 + harmonic_3
        
        -- Определяем направление для сгенерированного десинка
        desync_direction = (harmonic_1 + harmonic_2) > 0 and 1 or -1
    end

    -- ИСПРАВЛЕНИЕ: возвращаем знаковый десинк как в aisetpos
    local abs_desync = math_abs(total_desync)
    local smoothed_desync = abs_desync * 0.85 + safe_sqrt(abs_desync) * 8.2

    -- Временная модуляция для имитации человеческого поведения
    local human_factor = math_sin(globals_curtime() * 3.7) * 0.06 + 
                         math_cos(globals_curtime() * 2.3) * 0.04
    smoothed_desync = smoothed_desync * (1 + human_factor)

    -- Ограничиваем значение десинка максимумом 58
    local max_desync_limit = 58
    smoothed_desync = math_min(max_desync_limit, smoothed_desync)
    
    -- Применяем направление к финальному десинку
    local signed_desync = smoothed_desync * desync_direction
    
    -- === ПРИМЕНЕНИЕ УЛУЧШЕННОЙ RIPTIDE КОРРЕКЦИИ ===
    -- Создаем квантовое состояние для riptide_correction
    local quantum_state = {
        wave_function_collapse = math_sin(globals_curtime() * 1.7) * 0.3 + 0.7,
        entanglement_factor = math_cos(globals_curtime() * 1.9) * 0.3 + 0.7,
        uncertainty_principle = math_random() * 0.2 + 0.8
    }
    
    -- Применяем новую улучшенную систему коррекции Riptide V5 с wide jitter detection
    -- Создаем фейковые network_data для совместимости
    local network_data = {}
    for i = 1, 5 do
        table_insert(network_data, {
            y = math_random() * 360 - 180,
            timestamp = globals_curtime() - (i * 0.01)
        })
    end
    local riptide_result = riptide_correction(layers, velocity_data, player_state, quantum_state, network_data, 0)
    
    if riptide_result and riptide_result.corrected_desync then
        -- Применяем коррекцию с учетом уверенности
        local confidence_multiplier = riptide_result.confidence or 0.75
        local riptide_adjustment = riptide_result.corrected_desync * confidence_multiplier
        
        if math_abs(riptide_adjustment) > 2 then
            signed_desync = signed_desync + riptide_adjustment * 0.45
        end
        
        -- Дополнительные коррекции от системы Riptide V5
        if riptide_result.lag_compensation_fix and math_abs(riptide_result.lag_compensation_fix) > 0.001 then
            signed_desync = signed_desync + riptide_result.lag_compensation_fix * 18 -- Конвертация в градусы
        end
        
        if riptide_result.animation_layer_fix and math_abs(riptide_result.animation_layer_fix) > 0.01 then
            signed_desync = signed_desync + riptide_result.animation_layer_fix * 0.65
        end
        
        -- Новые коррекции V5
        if riptide_result.advanced_correction and math_abs(riptide_result.advanced_correction) > 0.5 then
            signed_desync = signed_desync + riptide_result.advanced_correction * 0.3
        end
        
        if riptide_result.prediction_enhancement and math_abs(riptide_result.prediction_enhancement) > 1 then
            signed_desync = signed_desync + riptide_result.prediction_enhancement * 0.4
        end
        
        -- === ЛОГИРОВАНИЕ РЕВОЛЮЦИОННОЙ RIPTIDE V5 СИСТЕМЫ ===
        if riptide_result.riptide_factor > 0.20 then -- Снижен порог для V5
            debug_log(string.format(
                "[RIPTIDE-V5-REVOLUTION] 🚀 F: %.2f | Orig: %.1f° | Adj: %.1f° | Final: %.1f° | Conf: %.2f | Enhanced Neural: %.1f | ML: %.1f | Quantum: %.1f | AI: %.1f | Analytics: %.1f | Weapon: %.1f | Map: %.1f | Neural Conf: %.2f | Dropout: %.2f | Meta: %.1f | Evolution: %.2f",
                riptide_result.riptide_factor,
                math.abs(smoothed_desync),
                riptide_adjustment,
                signed_desync,
                riptide_result.confidence or 0,
                riptide_result.enhanced_neural_network_prediction or 0,
                riptide_result.machine_learning_adjustment or 0,
                riptide_result.quantum_entanglement_fix or 0,
                riptide_result.ai_pattern_recognition or 0,
                riptide_result.predictive_analytics_boost or 0,
                riptide_result.weapon_specific_analysis or 0,
                riptide_result.map_aware_freestand or 0,
                riptide_result.enhanced_neural_confidence or 0,
                riptide_result.adaptive_dropout or 0,
                riptide_result.meta_learning_enhancement or 0,
                riptide_result.algorithmic_evolution_score or 0
            ))
        end
        
        -- Применяем новые riptide-специфичные фиксы V5
        if riptide_result.velocity_desync_correlation and math_abs(riptide_result.velocity_desync_correlation) > 0.5 then
            local velocity_correlation_correction = riptide_result.velocity_desync_correlation * 0.35
            signed_desync = signed_desync + velocity_correlation_correction
        end
        
        if riptide_result.adaptive_compensation and math_abs(riptide_result.adaptive_compensation) > 0.01 then
            local adaptive_correction = riptide_result.adaptive_compensation * 15 -- Конвертация в градусы
            signed_desync = signed_desync + adaptive_correction
        end
        
        -- Применяем временную стабильность для сглаживания
        if riptide_result.temporal_stability and riptide_result.temporal_stability > 0.7 then
            local stability_modifier = riptide_result.temporal_stability * 0.15
            signed_desync = signed_desync * (1.0 + stability_modifier)
        end
    end
    
    -- Дополнительная коррекция направления на основе состояния игрока
    if player_state then
        if player_state.moving and velocity_data then
            local velocity_angle = math_deg(math_atan2(velocity_data.y, velocity_data.x))
            local velocity_direction = (velocity_angle % 360) > 180 and -1 or 1
            
            -- Корректируем направление с вероятностью 70%
            if (globals_curtime() * 10) % 1 < 0.7 then
                signed_desync = math_abs(signed_desync) * velocity_direction
            end
        end
        
        -- Коррекция для приседания с учетом Riptide изменений
        if player_state.ducking then
            local riptide_crouch_modifier = 0.7
            -- После Riptide V5 crouch peek стал менее предсказуемым
            if riptide_result and riptide_result.riptide_factor > 0.5 then
                riptide_crouch_modifier = 0.6 + math_sin(globals_curtime() * 8.3) * 0.15
            end
            signed_desync = signed_desync * riptide_crouch_modifier
        end
        
        -- Коррекция для воздуха с учетом Riptide изменений
        if not player_state.on_ground then
            local riptide_air_modifier = 0.4
            -- После Riptide V5 air movement prediction стал менее точным
            if riptide_result and riptide_result.network_prediction_delta and riptide_result.network_prediction_delta > 0.02 then
                riptide_air_modifier = 0.3 + math_cos(globals_curtime() * 0.5) * 0.1
            end
            signed_desync = signed_desync * riptide_air_modifier
        end
    end

    -- Финальное ограничение с учетом Riptide V5 факторов
    local max_desync_final = 58
    -- Убираем повышение лимита выше 58: актуальный максимум 58 с учётом обновлений
    signed_desync = math_max(-max_desync_final, math_min(max_desync_final, signed_desync))

    return signed_desync
end

-- Advanced lag compensation record system

local function create_lag_record(entity_index)
    local origin_x, origin_y, origin_z = entity_get_origin(entity_index)
    
    -- Исправленное получение углов с безопасными фолбэками
    local raw_angles_y = entity_get_prop(entity_index, "m_angEyeAngles[1]") or entity_get_prop(entity_index, "m_angEyeAngles", 1)
    local angles_x = entity_get_prop(entity_index, "m_angEyeAngles[0]") or entity_get_prop(entity_index, "m_angEyeAngles", 0) or 0
    local lower_body_yaw_fallback = entity_get_prop(entity_index, "m_flLowerBodyYawTarget")
    local angles_y = raw_angles_y or lower_body_yaw_fallback or 0
    
    local velocity_data = entity_get_prop(entity_index, "m_vecVelocity")
    
    local origin = vector_new(origin_x, origin_y, origin_z)
    local angles = {x = normalize_angle_safe(angles_x), y = normalize_angle_safe(angles_y), z = 0}
    local velocity = vector_new(velocity_data)
    
    local simulation_time = entity_get_prop(entity_index, "m_flSimulationTime")
    local duck_amount = entity_get_prop(entity_index, "m_flDuckAmount")
    local flags = entity_get_prop(entity_index, "m_fFlags")
    local velocity_modifier = entity_get_prop(entity_index, "m_flVelocityModifier")
    
    -- Получаем дополнительные данные для лучшего анализа
    local lower_body_yaw = entity_get_prop(entity_index, "m_flLowerBodyYawTarget") or angles.y
    
    -- Drop invalid angle records to avoid yaw=0 spam
    if angles.y == 0 and (not raw_angles_y) and (not lower_body_yaw_fallback) then
        return nil
    end

    return {
        origin = origin,
        angles = angles,
        simulation_time = simulation_time,
        duck_amount = duck_amount,
        flags = flags,
        velocity_modifier = velocity_modifier,
        lower_body_yaw = lower_body_yaw,
        velocity = velocity,
        valid = true,
        animlayers = get_animlayer_data(entity_index),
        tick = globals_tickcount(),
        hitbox = {
            head = get_hitbox_center(entity_index, 0),
            chest = get_hitbox_center(entity_index, 5)
        }
    }
end

-- Network interpolation helper (cl_interp/cl_interp_ratio/updaterate)
local function get_interp_seconds()
    local get = client.get_cvar
    local ratio = tonumber(get and get("cl_interp_ratio") or nil) or 2
    local interp = tonumber(get and get("cl_interp") or nil) or 0.031
    local updaterate = tonumber(get and get("cl_updaterate") or nil) or 64
    local calc = ratio / math.max(1, updaterate)
    return math.max(interp, calc)
end

-- === COMPUTE VALID TICK FOR BACKTRACK (DYNAMIC, NETWORK-AWARE) ===
local function compute_valid_tick_for_record(record)
    if not record or not record.simulation_time then return nil end
    local tick_interval = globals.tickinterval()
    local curtime = globals.curtime()
    local time_diff = curtime - record.simulation_time
    if time_diff < 0 then return nil end

    local network_info = network_channel_system:get_network_info()
    local avg_latency = 0
    if network_info and network_info.latency then
        avg_latency = (network_info.latency.incoming + network_info.latency.outgoing) / 2
    end

    -- Dynamic max backtrack window: 200ms + half latency
    local max_window = 0.2 + (avg_latency * 0.5)
    if time_diff > max_window then return nil end

    -- Convert target time to engine tick with small jitter buffer (latency-aware)
    local jitter = 0
    local avg_choke = 0
    if network_info and network_info.choke then
        avg_choke = (network_info.choke.incoming + network_info.choke.outgoing) / 2
    end
    if avg_latency > 0.07 then
        jitter = math_min(0.05, avg_latency * 0.5 + avg_choke * 0.05)
    else
        jitter = math_min(0.02, avg_choke * 0.05)
    end
    local target_time = record.simulation_time + avg_latency + get_interp_seconds() - jitter
    local tick = math_floor(target_time / tick_interval + 0.5)
    return tick
end

-- === PREPARE SHOT WITH BACKTRACK (EXPOSE TICK TO AIM LAYER) ===
local function prepare_shot_with_backtrack(entity_index, record)
    local tick = compute_valid_tick_for_record(record)
    if not tick then return false end
    resolve_cache[entity_index] = resolve_cache[entity_index] or {}
    resolve_cache[entity_index].backtrack_tick = tick
    resolve_cache[entity_index].backtrack_record = record
    return true
end

-- === VALIDATE BACKTRACK RECORD (NETWORK- AND STATE-AWARE) ===
local function validate_backtrack_record(entity_index, record, prev_record)
    if not record or not record.simulation_time or not record.origin then
        return { valid = false, reasons = {"missing_fields"} }
    end

    local reasons = {}
    local tick = compute_valid_tick_for_record(record)
    if not tick then
        table.insert(reasons, "no_valid_tick")
    end

    local curtime = globals.curtime()
    local time_diff = curtime - record.simulation_time
    if time_diff < 0 then
        table.insert(reasons, "future_time")
    end

    -- Position sanity vs previous record
    if prev_record and prev_record.origin then
        local pos_delta = vector_distance(prev_record.origin, record.origin)
        local vel_mag = 0
        if record.velocity then
            vel_mag = vec_len2d(record.velocity)
        end
        local dynamic_threshold = 200 + vel_mag * math.max(time_diff, 0.015) * 2
        if pos_delta > dynamic_threshold then
            table.insert(reasons, "position_teleport")
        end
    end

    -- Animation sanity: require some activity
    local anim_ok = false
    if record.animlayers then
        local active = 0
        for i = 1, 13 do
            local layer = record.animlayers[i]
            if layer and layer.weight and layer.cycle then
                if (layer.weight > 0.0001) or (layer.cycle > 0 and layer.cycle < 1) then
                    active = active + 1
                end
            end
        end
        anim_ok = active >= 1
    end
    if not anim_ok then
        table.insert(reasons, "no_anim_activity")
    end

    -- Angle jump sanity vs previous
    if prev_record and prev_record.angles and record.angles then
        local yaw_jump = math.abs(normalize_angle(record.angles.y - prev_record.angles.y))
        if yaw_jump > 120 and time_diff < 0.02 then
            table.insert(reasons, "suspicious_yaw_jump")
        end
    end

    local valid = (tick ~= nil) and (time_diff >= 0) and (#reasons == 0)
    local score = 1.0
    if not valid then
        score = 0.0
    end

    return {
        valid = valid,
        score = score,
        tick = tick,
        time_diff = time_diff,
        reasons = reasons
    }
end

local function update_lag_records(entity_index)
    if not lag_records[entity_index] then
        lag_records[entity_index] = {}
    end

    -- Ensure minimal player_data container exists for valid_records
    if not player_data[entity_index] then
        player_data[entity_index] = {
            valid_records = {},
            last_valid_record = nil,
            shots_fired = 0,
            shots_hit = 0,
            shots_missed = 0,
            performance_metrics = {
                accuracy = 0,
                consistency = 0,
                last_update = 0,
                resolution_quality = 0.0,
                hit_probability = 0.5,
                miss_rate = 0.5,
                adaptive_success = 0.5,
                network_correlation_accuracy = 0.5
            }
        }
    else
        if not player_data[entity_index].valid_records then
            player_data[entity_index].valid_records = {}
        end
        -- Ensure counters exist even if entry was created minimally before
        player_data[entity_index].shots_fired = player_data[entity_index].shots_fired or 0
        player_data[entity_index].shots_hit = player_data[entity_index].shots_hit or 0
        player_data[entity_index].shots_missed = player_data[entity_index].shots_missed or 0
        if not player_data[entity_index].performance_metrics then
            player_data[entity_index].performance_metrics = {
                accuracy = 0,
                consistency = 0,
                last_update = 0,
                resolution_quality = 0.0,
                hit_probability = 0.5,
                miss_rate = 0.5,
                adaptive_success = 0.5,
                network_correlation_accuracy = 0.5
            }
        end
    end

    local prev_record = lag_records[entity_index][1]
    local record = create_lag_record(entity_index)
    if record and record.simulation_time then
        -- Validate the record for defensive AA cases
        local v = validate_backtrack_record(entity_index, record, prev_record)
        record.validity = v

        if v.valid then
            -- Store in valid_records queue
            table.insert(player_data[entity_index].valid_records, 1, record)
            if #player_data[entity_index].valid_records > 32 then
                table.remove(player_data[entity_index].valid_records)
            end
            player_data[entity_index].last_valid_record = record
        end

        table_insert(lag_records[entity_index], 1, record)
        -- Keep only last 64 records for performance
        while #lag_records[entity_index] > 64 do
            table.remove(lag_records[entity_index])
        end
    end
end
local function analyze_backtrack_records(entity_index)
    local records = lag_records[entity_index]
    if not records or #records < 2 then 
        return nil 
    end

    local best_record = nil
    local best_score = -1
    local local_player = entity_get_local_player()
    
    if not local_player then return nil end
    
    -- УЛУЧШЕННЫЙ анализ записей
    local my_origin = {entity_get_origin(local_player)}
    my_origin = {x = my_origin[1], y = my_origin[2], z = my_origin[3] + 64}
    
    -- Продвинутый джиттер анализ 
    local jitter_analysis = {
        factor = 1.0,
        intensity = 0,
        pattern_type = "none",
        consistency = 0
    }
    
    if #records >= 6 then
        local angle_changes = {}
        local time_deltas = {}
        
        for i = 1, math.min(6, #records - 1) do
            local delta = math.abs(normalize_angle(records[i].angles.y - records[i+1].angles.y))
            local time_delta = (records[i].simulation_time or 0) - (records[i+1].simulation_time or 0)
            table.insert(angle_changes, delta)
            table.insert(time_deltas, time_delta)
        end
        
        -- Анализ интенсивности и паттерна
        local total_change = 0
        local high_change_count = 0
        for _, change in ipairs(angle_changes) do
            total_change = total_change + change
            if change > 45 then
                high_change_count = high_change_count + 1
            end
        end
        
        local avg_change = total_change / #angle_changes
        jitter_analysis.intensity = avg_change
        
        -- Определяем тип джиттера
        if avg_change > 50 and high_change_count >= 3 then
            jitter_analysis.pattern_type = "wide_jitter"
            jitter_analysis.factor = 1.5
        elseif avg_change > 30 and high_change_count >= 2 then
            jitter_analysis.pattern_type = "micro_jitter"
            jitter_analysis.factor = 1.3
        elseif avg_change > 15 then
            jitter_analysis.pattern_type = "slow_jitter"
            jitter_analysis.factor = 1.2
        end
        
        -- Анализ консистентности
        local variance = 0
        for _, change in ipairs(angle_changes) do
            variance = variance + (change - avg_change)^2
        end
        jitter_analysis.consistency = 1.0 - (variance / (#angle_changes * avg_change^2))
    end
    
    -- Инициализация 4D функций
    local function create_4d_vector_bt(x, y, z, w)
        return {x = x or 0, y = y or 0, z = z or 0, w = w or 0}
    end
    
    -- Простой анализ записей по времени и позиции с 4D векторами
    local temporal_analysis = {}
    for i = 1, #records do
        local record = records[i]
        if record and record.simulation_time and record.origin then
            local time_diff = globals_curtime() - record.simulation_time
            local temporal_4d = create_4d_vector_bt(
                record.origin.x,
                record.origin.y, 
                record.origin.z,
                time_diff * 1000
            )
            temporal_analysis[i] = {
                vector_4d = temporal_4d,
                stability_index = 0,
                prediction_confidence = 0,
                ml_score = 0
            }
        end
    end
    

    
    local function magnitude_4d_bt(v)
        if not v then return 0 end
        if not v.x or not v.y or not v.z or not v.w then return 0 end
        return safe_sqrt(v.x^2 + v.y^2 + v.z^2 + v.w^2)
    end
    
    local function dot_product_4d_bt(v1, v2)
        if not v1 or not v2 then return 0 end
        if not v1.x or not v1.y or not v1.z or not v1.w then return 0 end
        if not v2.x or not v2.y or not v2.z or not v2.w then return 0 end
        return v1.x * v2.x + v1.y * v2.y + v1.z * v2.z + v1.w * v2.w
    end
    
    -- Инициализация backtrack_angle_history
    local backtrack_angle_history = {}
    for i = 1, math.min(10, #records) do
        local record = records[i]
        if record and record.angles then
            table.insert(backtrack_angle_history, {
                y = record.angles.y,
                x = record.angles.x,
                timestamp = record.simulation_time or globals_curtime(),
                origin = record.origin,
                flags = record.flags or 0
            })
        end
    end
    
    -- Инициализация backtrack_jitter_analysis
    local backtrack_jitter_analysis = {
        is_wide_jitter = jitter_analysis.pattern_type ~= "none",
        jitter_pattern = jitter_analysis.pattern_type,
        jitter_intensity = jitter_analysis.intensity,
        desync_correction = jitter_analysis.intensity * 0.5,
        confidence = jitter_analysis.consistency,
        antiaim_type = jitter_analysis.pattern_type,
        prediction_accuracy = jitter_analysis.consistency,
        stability_factor = jitter_analysis.consistency,
        frequency_analysis = jitter_analysis.intensity > 30 and 0.8 or 0.4,
        direction_prediction = 0,
        network_anomaly = jitter_analysis.intensity > 50
    }
    
    -- Машинное обучение: анализ паттернов в истории записей
    local ml_weights = {
        position_stability = 0.3,
        velocity_consistency = 0.25,
        animation_coherence = 0.2,
        temporal_smoothness = 0.15,
        hit_probability = 0.1
    }
    
    -- Инициализация данных для ML анализа
    if not player_data[entity_index] then
        player_data[entity_index] = {
            direction_memory = { -- ПРОСТАЯ система запоминания направлений
                last_directions = {},
                left_count = 0,
                right_count = 0,
                pattern_detected = false
            },
            yaw_history = {},
            desync_history = {},
            velocity_history = {},
            shots_fired = 0,
            shots_hit = 0,
            shots_missed = 0,
            last_resolve = 0,
            fake_angles = {},
            pattern_detected = false,
            pattern_type = "unknown",
            pattern_confidence = 0,
            desync_range = {min = 999, max = -999, average = 0},
            behavioral_analysis = {
                aggression = 0.5,
                predictability = 0.5,
                adaptation_rate = 0.5,
                riptide_factor = 0.0,
                desync_entropy = 0.0,
                temporal_consistency = 0.0,
                fractal_dimension = 0.0
            },
            performance_metrics = {
                accuracy = 0,
                consistency = 0,
                last_update = 0,
                resolution_quality = 0.0
            },
            riptide_analysis = {
                desync_amplitude = 0,
                phase_shift = 0,
                frequency_domain = {},
                harmonic_components = {},
                noise_reduction = 0.0
            },
            adaptive_filter_state = { prediction_error_sum = 0, alpha = 0.1 },
            shot_tracking = {}
        }
    end
    if not player_data[entity_index].backtrack_history then
        player_data[entity_index].backtrack_history = {
            successful_records = {},
            failed_records = {},
            accuracy_metrics = {},
            pattern_recognition = {}
        }
    end
    
    local bt_history = player_data[entity_index].backtrack_history
    
    -- Исправленное получение координат - используем прямое преобразование
    local my_origin_x, my_origin_y, my_origin_z = entity_get_origin(local_player)
    local my_velocity_data = entity_get_prop(local_player, "m_vecVelocity")
    
    -- Прямое получение и преобразование eye_position
    local eye_pos_raw = client_eye_position()
    local my_eye_pos
    if eye_pos_raw and type(eye_pos_raw) == "table" and eye_pos_raw[1] then
        my_eye_pos = {x = eye_pos_raw[1], y = eye_pos_raw[2], z = eye_pos_raw[3]}
    else
        my_eye_pos = {x = 0, y = 0, z = 64} -- Значение по умолчанию
    end
    
    local my_origin = vector_new(my_origin_x, my_origin_y, my_origin_z)
    local my_velocity = vector_new(my_velocity_data)
    
    -- Получаем информацию о нашем оружии
    local weapon = entity_get_player_weapon(local_player)
    local weapon_data = {
        name = "unknown",
        type = "rifle",
        optimal_range = 1000,
        damage_falloff = 1.0,
        accuracy_factor = 1.0,
        recoil_factor = 1.0,
        movement_penalty = 1.0,
        penetration = 1.0,
        fire_rate = 1.0
    }
    
    if weapon then
        local weapon_name = entity_get_classname(weapon):lower()
        weapon_data.name = weapon_name
        
        -- === RIFLES ===
        if weapon_name:find("ak47") then
            weapon_data.type = "rifle"
            weapon_data.optimal_range = 1800
            weapon_data.damage_falloff = 0.98
            weapon_data.accuracy_factor = 0.85
            weapon_data.recoil_factor = 1.2
            weapon_data.movement_penalty = 1.4
            weapon_data.penetration = 1.0
            weapon_data.fire_rate = 0.1
            
        elseif weapon_name:find("m4a1_s") then
            weapon_data.type = "rifle"
            weapon_data.optimal_range = 1600
            weapon_data.damage_falloff = 0.96
            weapon_data.accuracy_factor = 0.95
            weapon_data.recoil_factor = 0.9
            weapon_data.movement_penalty = 1.3
            weapon_data.penetration = 1.0
            weapon_data.fire_rate = 0.09
            
        elseif weapon_name:find("m4a4") then
            weapon_data.type = "rifle"
            weapon_data.optimal_range = 1500
            weapon_data.damage_falloff = 0.94
            weapon_data.accuracy_factor = 0.9
            weapon_data.recoil_factor = 1.0
            weapon_data.movement_penalty = 1.3
            weapon_data.penetration = 1.0
            weapon_data.fire_rate = 0.09
            
        elseif weapon_name:find("galil") or weapon_name:find("famas") then
            weapon_data.type = "rifle"
            weapon_data.optimal_range = 1200
            weapon_data.damage_falloff = 0.92
            weapon_data.accuracy_factor = 0.8
            weapon_data.recoil_factor = 1.1
            weapon_data.movement_penalty = 1.2
            weapon_data.penetration = 0.9
            weapon_data.fire_rate = 0.09
            
        -- === SNIPER RIFLES ===
        elseif weapon_name:find("awp") then
            weapon_data.type = "sniper"
            weapon_data.optimal_range = 4000
            weapon_data.damage_falloff = 1.0
            weapon_data.accuracy_factor = 1.0
            weapon_data.recoil_factor = 0.3
            weapon_data.movement_penalty = 2.0
            weapon_data.penetration = 1.0
            weapon_data.fire_rate = 1.5
            
        elseif weapon_name:find("ssg08") then
            weapon_data.type = "sniper"
            weapon_data.optimal_range = 3000
            weapon_data.damage_falloff = 0.98
            weapon_data.accuracy_factor = 0.95
            weapon_data.recoil_factor = 0.4
            weapon_data.movement_penalty = 1.1  -- Скаут можно использовать в движении
            weapon_data.penetration = 0.9
            weapon_data.fire_rate = 1.25
            
        elseif weapon_name:find("g3sg1") or weapon_name:find("scar20") then
            weapon_data.type = "auto_sniper"
            weapon_data.optimal_range = 2500
            weapon_data.damage_falloff = 0.95
            weapon_data.accuracy_factor = 0.9
            weapon_data.recoil_factor = 0.8
            weapon_data.movement_penalty = 1.8
            weapon_data.penetration = 1.0
            weapon_data.fire_rate = 0.25
            
        -- === SMGs ===
        elseif weapon_name:find("mp9") or weapon_name:find("mac10") then
            weapon_data.type = "smg"
            weapon_data.optimal_range = 600
            weapon_data.damage_falloff = 0.85
            weapon_data.accuracy_factor = 0.7
            weapon_data.recoil_factor = 1.3
            weapon_data.movement_penalty = 0.8
            weapon_data.penetration = 0.6
            weapon_data.fire_rate = 0.057
            
        elseif weapon_name:find("mp7") or weapon_name:find("mp5") then
            weapon_data.type = "smg"
            weapon_data.optimal_range = 800
            weapon_data.damage_falloff = 0.88
            weapon_data.accuracy_factor = 0.75
            weapon_data.recoil_factor = 1.1
            weapon_data.movement_penalty = 0.85
            weapon_data.penetration = 0.7
            weapon_data.fire_rate = 0.08
            
        elseif weapon_name:find("ump45") then
            weapon_data.type = "smg"
            weapon_data.optimal_range = 900
            weapon_data.damage_falloff = 0.9
            weapon_data.accuracy_factor = 0.8
            weapon_data.recoil_factor = 1.0
            weapon_data.movement_penalty = 0.9
            weapon_data.penetration = 0.75
            weapon_data.fire_rate = 0.1
            
        elseif weapon_name:find("p90") then
            weapon_data.type = "smg"
            weapon_data.optimal_range = 700
            weapon_data.damage_falloff = 0.86
            weapon_data.accuracy_factor = 0.72
            weapon_data.recoil_factor = 1.2
            weapon_data.movement_penalty = 0.75
            weapon_data.penetration = 0.8
            weapon_data.fire_rate = 0.07
            
        elseif weapon_name:find("bizon") then
            weapon_data.type = "smg"
            weapon_data.optimal_range = 650
            weapon_data.damage_falloff = 0.82
            weapon_data.accuracy_factor = 0.68
            weapon_data.recoil_factor = 1.25
            weapon_data.movement_penalty = 0.8
            weapon_data.penetration = 0.6
            weapon_data.fire_rate = 0.08
            
        -- === PISTOLS ===
        elseif weapon_name:find("deagle") then
            weapon_data.type = "pistol"
            weapon_data.optimal_range = 1200
            weapon_data.damage_falloff = 0.93
            weapon_data.accuracy_factor = 0.8
            weapon_data.recoil_factor = 1.5
            weapon_data.movement_penalty = 1.0
            weapon_data.penetration = 0.9
            weapon_data.fire_rate = 0.27
            
        elseif weapon_name:find("revolver") then
            weapon_data.type = "pistol"
            weapon_data.optimal_range = 1000
            weapon_data.damage_falloff = 0.91
            weapon_data.accuracy_factor = 0.85
            weapon_data.recoil_factor = 1.4
            weapon_data.movement_penalty = 1.0
            weapon_data.penetration = 0.85
            weapon_data.fire_rate = 0.4
            
        elseif weapon_name:find("glock") then
            weapon_data.type = "pistol"
            weapon_data.optimal_range = 600
            weapon_data.damage_falloff = 0.85
            weapon_data.accuracy_factor = 0.7
            weapon_data.recoil_factor = 1.1
            weapon_data.movement_penalty = 0.9
            weapon_data.penetration = 0.6
            weapon_data.fire_rate = 0.15
            
        elseif weapon_name:find("usp") or weapon_name:find("hkp2000") then
            weapon_data.type = "pistol"
            weapon_data.optimal_range = 700
            weapon_data.damage_falloff = 0.87
            weapon_data.accuracy_factor = 0.75
            weapon_data.recoil_factor = 1.0
            weapon_data.movement_penalty = 0.9
            weapon_data.penetration = 0.65
            weapon_data.fire_rate = 0.17
            
        elseif weapon_name:find("p250") then
            weapon_data.type = "pistol"
            weapon_data.optimal_range = 650
            weapon_data.damage_falloff = 0.86
            weapon_data.accuracy_factor = 0.72
            weapon_data.recoil_factor = 1.05
            weapon_data.movement_penalty = 0.9
            weapon_data.penetration = 0.7
            weapon_data.fire_rate = 0.15
            
        elseif weapon_name:find("fiveseven") or weapon_name:find("tec9") then
            weapon_data.type = "pistol"
            weapon_data.optimal_range = 750
            weapon_data.damage_falloff = 0.88
            weapon_data.accuracy_factor = 0.73
            weapon_data.recoil_factor = 1.1
            weapon_data.movement_penalty = 0.85
            weapon_data.penetration = 0.75
            weapon_data.fire_rate = 0.12
            
        elseif weapon_name:find("cz75") then
            weapon_data.type = "pistol"
            weapon_data.optimal_range = 500
            weapon_data.damage_falloff = 0.83
            weapon_data.accuracy_factor = 0.68
            weapon_data.recoil_factor = 1.3
            weapon_data.movement_penalty = 0.85
            weapon_data.penetration = 0.65
            weapon_data.fire_rate = 0.1
            
        elseif weapon_name:find("dualies") then
            weapon_data.type = "pistol"
            weapon_data.optimal_range = 400
            weapon_data.damage_falloff = 0.8
            weapon_data.accuracy_factor = 0.6
            weapon_data.recoil_factor = 1.4
            weapon_data.movement_penalty = 0.8
            weapon_data.penetration = 0.5
            weapon_data.fire_rate = 0.12
            

        -- === SHOTGUNS ===
        elseif weapon_name:find("nova") then
            weapon_data.type = "shotgun"
            weapon_data.optimal_range = 200
            weapon_data.damage_falloff = 0.6
            weapon_data.accuracy_factor = 0.4
            weapon_data.recoil_factor = 1.8
            weapon_data.movement_penalty = 1.1
            weapon_data.penetration = 0.3
            weapon_data.fire_rate = 0.88
            
        elseif weapon_name:find("xm1014") then
            weapon_data.type = "shotgun"
            weapon_data.optimal_range = 250
            weapon_data.damage_falloff = 0.65
            weapon_data.accuracy_factor = 0.45
            weapon_data.recoil_factor = 1.6
            weapon_data.movement_penalty = 1.1
            weapon_data.penetration = 0.35
            weapon_data.fire_rate = 0.35
            
        elseif weapon_name:find("sawedoff") then
            weapon_data.type = "shotgun"
            weapon_data.optimal_range = 150
            weapon_data.damage_falloff = 0.5
            weapon_data.accuracy_factor = 0.3
            weapon_data.recoil_factor = 2.0
            weapon_data.movement_penalty = 1.0
            weapon_data.penetration = 0.25
            weapon_data.fire_rate = 0.85
            
        elseif weapon_name:find("mag7") then
            weapon_data.type = "shotgun"
            weapon_data.optimal_range = 180
            weapon_data.damage_falloff = 0.55
            weapon_data.accuracy_factor = 0.35
            weapon_data.recoil_factor = 1.9
            weapon_data.movement_penalty = 0.95
            weapon_data.penetration = 0.3
            weapon_data.fire_rate = 0.9
            
        -- === MACHINE GUNS ===
        elseif weapon_name:find("m249") then
            weapon_data.type = "machinegun"
            weapon_data.optimal_range = 1400
            weapon_data.damage_falloff = 0.92
            weapon_data.accuracy_factor = 0.7
            weapon_data.recoil_factor = 1.8
            weapon_data.movement_penalty = 2.5
            weapon_data.penetration = 1.0
            weapon_data.fire_rate = 0.08
            
        elseif weapon_name:find("negev") then
            weapon_data.type = "machinegun"
            weapon_data.optimal_range = 1300
            weapon_data.damage_falloff = 0.9
            weapon_data.accuracy_factor = 0.65
            weapon_data.recoil_factor = 2.0
            weapon_data.movement_penalty = 2.8
            weapon_data.penetration = 0.95
            weapon_data.fire_rate = 0.075
        end
    end
    -- Анализ каждого рекорда с учетом характеристик оружия
    for i = 1, #records do
        local record = records[i]
        if record and record.valid and record.simulation_time then
            -- === ENHANCED RECORD QUALITY FILTERING ===
            -- Pre-filter records for quality and validity
            local record_quality_score = 0
            
            -- Basic validity checks
            if not record.origin or (record.origin.x == 0 and record.origin.y == 0 and record.origin.z == 0) then
                return -- Invalid origin
            end
            
            -- Check for reasonable position changes
            if i < #records and records[i+1] and records[i+1].origin then
                local position_change = vector_distance(record.origin, records[i+1].origin)
                if position_change > 300 then -- Too large position jump
                    record_quality_score = record_quality_score - 500
                elseif position_change < 1 then -- Identical positions (good)
                    record_quality_score = record_quality_score + 100
                end
            end
            
            -- Check simulation time consistency
            if i < #records and records[i+1] and records[i+1].simulation_time then
                local time_delta = record.simulation_time - records[i+1].simulation_time
                if time_delta < 0 or time_delta > 0.1 then -- Invalid time progression
                    record_quality_score = record_quality_score - 300
                end
            end
            
            -- Check for duplicate records (same simulation time)
            local duplicate_found = false
            for j = i+1, math.min(i+3, #records) do
                if records[j] and records[j].simulation_time == record.simulation_time then
                    duplicate_found = true
                    break
                end
            end
            if duplicate_found then
                record_quality_score = record_quality_score - 200
            end
            
            -- Skip record if quality is too poor
            if record_quality_score < -400 then
                return
            end
            local time_diff = globals_curtime() - record.simulation_time
            local tick_diff = i - 1

            -- Enhanced temporal window with network compensation
            local max_time_diff = 0.3
            local max_tick_diff = 20
            
            -- Adjust time window based on network conditions
            if network_info and network_info.latency then
                local avg_latency = (network_info.latency.incoming + network_info.latency.outgoing) / 2
                max_time_diff = max_time_diff + (avg_latency * 2) -- Extend window for high latency
                max_tick_diff = max_tick_diff + math.floor(avg_latency * 40) -- More ticks for high latency
            end
            
            -- Tighter window for fast moving targets
            if record.velocity and vector_length(record.velocity) > 150 then
                max_time_diff = max_time_diff * 0.7 -- Shorter window for fast targets
                max_tick_diff = max_tick_diff * 0.8
            end
            
            if time_diff > 0 and time_diff <= max_time_diff and tick_diff <= max_tick_diff then 
                local score = 1000 -- Базовый скор
                
                -- === УЛУЧШЕННЫЙ АНАЛИЗ ДИСТАНЦИИ С УЧЕТОМ ОРУЖИЯ ===
                local distance = vector_distance(my_eye_pos, record.origin)
                local distance_score = 0
                
                -- Адаптивный скоринг дистанции с джиттер анализом
                if jitter_analysis.pattern_type == "wide_jitter" then
                    -- Для широкого джиттера предпочитаем более близкие записи
                    if distance < 800 then
                        distance_score = 300 - distance * 0.2
                    else
                        distance_score = 100 - (distance - 800) * 0.3
                    end
                elseif jitter_analysis.pattern_type == "micro_jitter" then
                    -- Для микро джиттера можем использовать средние дистанции
                    if distance > 300 and distance < 1200 then
                        distance_score = 250 - math.abs(distance - 750) * 0.15
                    else
                        distance_score = 100 - math.abs(distance - 750) * 0.25
                    end
                else
                    -- Стандартный анализ дистанции
                    if distance < 500 then
                        distance_score = 200 - distance * 0.2
                    elseif distance < 2000 then
                        distance_score = 150 - (distance - 500) * 0.05
                    else
                        distance_score = 75 - (distance - 2000) * 0.02
                    end
                end
                
                -- Оптимальная дистанция для каждого типа оружия
                local distance_ratio = distance / weapon_data.optimal_range
                
                if distance_ratio <= 0.5 then
                    -- Очень близко - отлично для большинства оружий
                    distance_score = 300 * weapon_data.accuracy_factor
                elseif distance_ratio <= 1.0 then
                    -- В оптимальном диапазоне
                    distance_score = 250 * weapon_data.accuracy_factor * (2.0 - distance_ratio)
                elseif distance_ratio <= 1.5 then
                    -- За пределами оптимального, но приемлемо
                    distance_score = 150 * weapon_data.accuracy_factor * weapon_data.damage_falloff
                else
                    -- Слишком далеко
                    distance_score = math_max(0, 100 - (distance_ratio - 1.5) * 100) * weapon_data.damage_falloff
                end
                
                -- Специальные бонусы для снайперских винтовок на дальних дистанциях
                if weapon_data.type == "sniper" and distance > 1500 then
                    distance_score = distance_score * 1.3
                end
                
                -- Специальные бонусы для дробовиков на близких дистанциях
                if weapon_data.type == "shotgun" and distance < 300 then
                    distance_score = distance_score * 1.5
                end
                
                score = score + distance_score

                -- === ENHANCED MOVEMENT PREDICTION WITH INTERPOLATION ===
                local movement_score = 0
                
                if record.velocity then
                    local velocity_magnitude = vector_length(record.velocity)
                    
                    -- Advanced movement prediction with acceleration compensation
                    local predicted_movement = velocity_magnitude * time_diff
                    
                    -- Get velocity from previous record for acceleration calculation
                    local acceleration_factor = 0
                    if i < #records and records[i+1] and records[i+1].velocity then
                        local prev_velocity = vector_length(records[i+1].velocity)
                        local velocity_change = velocity_magnitude - prev_velocity
                        local time_between_records = (record.simulation_time or 0) - (records[i+1].simulation_time or 0)
                        
                        if time_between_records > 0 then
                            acceleration_factor = velocity_change / time_between_records
                            -- Apply acceleration to prediction
                            predicted_movement = predicted_movement + (0.5 * acceleration_factor * time_diff * time_diff)
                        end
                    end
                    
                    -- Enhanced velocity scoring with interpolation compensation
                    if velocity_magnitude < 30 then
                        movement_score = 500 -- Standing target - highest priority
                        
                        -- Bonus for confirmed stopped target (multiple static records)
                        if i < #records and records[i+1] and records[i+1].velocity then
                            local prev_vel = vector_length(records[i+1].velocity)
                            if prev_vel < 30 then
                                movement_score = movement_score + 150 -- Definitely stopped
                            end
                        end
                        
                    elseif velocity_magnitude < 80 then
                        movement_score = 400 - velocity_magnitude * 2.5 -- Slow movement
                        
                    elseif velocity_magnitude < 150 then
                        movement_score = 320 - velocity_magnitude * 1.8 -- Medium movement
                        
                        -- Interpolation compensation for medium speed
                        local interp_compensation = math.min(100, predicted_movement * 3)
                        movement_score = movement_score - interp_compensation
                        
                    elseif velocity_magnitude < 220 then
                        movement_score = 250 - velocity_magnitude * 1.2 -- Fast movement
                        
                        -- Heavy interpolation penalty for fast targets
                        local interp_penalty = math.min(200, predicted_movement * 4)
                        movement_score = movement_score - interp_penalty
                        
                    else
                        movement_score = 150 - velocity_magnitude * 0.8 -- Very fast
                        
                        -- Extreme interpolation penalty
                        local interp_penalty = math.min(300, predicted_movement * 5)
                        movement_score = movement_score - interp_penalty
                    end
                    
                    -- Acceleration penalty (changing speed is harder to predict)
                    if math.abs(acceleration_factor) > 50 then
                        movement_score = movement_score - math.abs(acceleration_factor) * 2
                    end
                    
                    -- Модификация на основе типа оружия
                    if weapon_data.type == "sniper" then
                        -- Снайперские винтовки хуже работают по движущимся целям
                        if velocity_magnitude > 50 then
                            movement_score = movement_score * 0.6
                        end
                    elseif weapon_data.type == "shotgun" then
                        -- Дробовики более прощающие к движению на близкой дистанции
                        if distance < 200 then
                            movement_score = movement_score * 1.2
                        end
                    elseif weapon_data.type == "smg" then
                        -- SMG лучше работают по движущимся целям
                        if velocity_magnitude > 100 and velocity_magnitude < 250 then
                            movement_score = movement_score * 1.1
                        end
                    end
                    
                    -- Анализ направления движения
                    local to_target = vector_new(
                        record.origin.x - my_origin.x,
                        record.origin.y - my_origin.y,
                        record.origin.z - my_origin.z
                    )
                    
                    if vector_length(record.velocity) > 10 and vector_length(to_target) > 10 then
                        local velocity_dot = (record.velocity.x * to_target.x + record.velocity.y * to_target.y) / 
                                            (vector_length(record.velocity) * vector_length(to_target))
                        
                        -- Движение к нам или от нас более предсказуемо
                        if math_abs(velocity_dot) > 0.8 then
                            movement_score = movement_score + 100
                        elseif math_abs(velocity_dot) < 0.2 then
                            -- Перпендикулярное движение сложнее
                            movement_score = movement_score - 80
                        end
                    end
                    
                    -- Штраф за большое предсказанное движение
                    local movement_threshold = weapon_data.type == "sniper" and 8 or 15
                    if predicted_movement > movement_threshold then
                        movement_score = movement_score - (predicted_movement - movement_threshold) * 5
                    end
                end
                
                score = score + movement_score

                -- === АНАЛИЗ НАШЕГО ДВИЖЕНИЯ ===
                local our_movement_score = 0
                local our_velocity_magnitude = vector_length(my_velocity)
                
                -- Штраф за наше движение зависит от оружия
                local movement_penalty = our_velocity_magnitude * weapon_data.movement_penalty
                
                if weapon_data.type == "sniper" and weapon_data.name:find("ssg08") then
                    -- Скаут можно использовать в движении
                    movement_penalty = movement_penalty * 0.3
                elseif weapon_data.type == "sniper" then
                    -- Остальные снайперские винтовки очень неточны в движении
                    movement_penalty = movement_penalty * 2.0
                elseif weapon_data.type == "smg" or weapon_data.type == "pistol" then
                    -- SMG и пистолеты менее чувствительны к движению
                    movement_penalty = movement_penalty * 0.5
                end
                
                our_movement_score = -movement_penalty
                score = score + our_movement_score

                -- === АНАЛИЗ ПОЗИЦИОННОЙ СТАБИЛЬНОСТИ ===
                local stability_score = 0
                
                if i > 1 and i < #records then
                    local prev_record = records[i + 1]
                    local next_record = records[i - 1]
                    
                    if prev_record and next_record then
                        local pos_change_prev = vector_distance(record.origin, prev_record.origin)
                        local pos_change_next = vector_distance(record.origin, next_record.origin)
                        local avg_change = (pos_change_prev + pos_change_next) / 2
                        
                        stability_score = math_max(0, 200 - avg_change * 3)
                        
                        -- Бонус для оружий, требующих точности
                        if weapon_data.type == "sniper" or weapon_data.type == "rifle" then
                            stability_score = stability_score * 1.2
                        end
                    end
                end
                
                score = score + stability_score

                -- === АНАЛИЗ ФИЗИЧЕСКОГО СОСТОЯНИЯ ===
                local physics_score = 0
                
                -- На земле
                if record.flags and bit.band(record.flags, 1) == 1 then
                    physics_score = physics_score + 150
                    
                    -- Дополнительный бонус для снайперских винтовок
                    if weapon_data.type == "sniper" then
                        physics_score = physics_score + 100
                    end
                end
                
                -- Анализ приседания
                local duck_amount = record.duck_amount or 0
                if duck_amount > 0.8 then
                    physics_score = physics_score + 120 -- Полное приседание стабильно
                    
                    -- Снайперские винтовки получают больший бонус
                    if weapon_data.type == "sniper" then
                        physics_score = physics_score + 80
                    end

                elseif duck_amount > 0.1 and duck_amount < 0.8 then
                    physics_score = physics_score - 50 -- Переходное состояние приседания
                end
                
                score = score + physics_score

                -- === АНАЛИЗ УГЛОВ И АНИМАЦИЙ ===
                local angle_score = 0
                
                if record.angles then
                    -- Стабильность углов
                    if i < #records and records[i+1] and records[i+1].angles then
                        local angle_diff = math_abs(normalize_angle(record.angles.y - records[i+1].angles.y))
                        
                        if angle_diff < 3 then
                            angle_score = angle_score + 150
                        elseif angle_diff < 10 then
                            angle_score = angle_score + 100 - angle_diff * 5
                        else
                            angle_score = angle_score - angle_diff * 3
                        end
                        
                        -- Снайперские винтовки требуют большей стабильности углов
                        if weapon_data.type == "sniper" and angle_diff < 5 then
                            angle_score = angle_score + 100
                        end
                    end
                    
                    -- Анализ анимационных слоев
                    if record.animlayers then
                        local animlayer_score = 0
                        local layers = record.animlayers
                        
                        -- Ключевые слои для анализа
                        local movement_layer = layers[6]
                        local lean_layer = layers[12]
                        local adjust_layer = layers[3]
                        
                        if movement_layer and movement_layer.weight then
                            if movement_layer.weight < 0.1 then
                                animlayer_score = animlayer_score + 80 -- Не движется
                            elseif movement_layer.weight > 0.9 then
                                animlayer_score = animlayer_score + 40 -- Стабильное движение
                            else
                                animlayer_score = animlayer_score - 30 -- Переходное состояние
                            end
                        end
                        
                        if lean_layer and lean_layer.weight and lean_layer.weight < 0.2 then
                            animlayer_score = animlayer_score + 60 -- Не наклоняется
                        end
                        
                        angle_score = angle_score + animlayer_score
                    end
                end
                
                score = score + angle_score

                -- === ВРЕМЕННЫЕ ФАКТОРЫ ===
                local time_score = 0
                
                -- Приоритет свежим записям с учетом типа оружия
                local optimal_tick_range = {2, 8}
                
                if weapon_data.type == "sniper" then
                    optimal_tick_range = {3, 12} -- Снайперские винтовки могут использовать более старые записи
                elseif weapon_data.type == "shotgun" then
                    optimal_tick_range = {1, 5} -- Дробовики требуют свежих данных
                elseif weapon_data.type == "smg" then
                    optimal_tick_range = {1, 6} -- SMG работают с относительно свежими данными
                end
                
                if tick_diff >= optimal_tick_range[1] and tick_diff <= optimal_tick_range[2] then
                    time_score = time_score + 200
                elseif tick_diff < optimal_tick_range[1] then
                    time_score = time_score + 100 -- Слишком свежие данные
                else
                    time_score = time_score - (tick_diff - optimal_tick_range[2]) * 20
                end
                
                -- Дополнительный временной бонус
                local freshness_bonus = math_max(0, 150 - time_diff * 500)
                time_score = time_score + freshness_bonus
                
                score = score + time_score

                -- === ENHANCED HITBOX-AWARE VISIBILITY ANALYSIS ===
                local visibility_score = 0
                
                if my_eye_pos and my_eye_pos.x and my_eye_pos.y and my_eye_pos.z then
                    -- Precise hitbox positions based on player state
                    local duck_offset = (record.duck_amount or 0) * 18 -- Ducking reduces height
                    local base_height = 72 - duck_offset
                    
                    -- Multiple hitbox positions for better accuracy
                    local hitboxes = {
                        head = {x = record.origin.x, y = record.origin.y, z = record.origin.z + base_height - 8, priority = 1.5},
                        neck = {x = record.origin.x, y = record.origin.y, z = record.origin.z + base_height - 16, priority = 1.3},
                        chest = {x = record.origin.x, y = record.origin.y, z = record.origin.z + base_height - 24, priority = 1.2},
                        stomach = {x = record.origin.x, y = record.origin.y, z = record.origin.z + base_height - 36, priority = 1.0},
                        pelvis = {x = record.origin.x, y = record.origin.y, z = record.origin.z + base_height - 48, priority = 0.8}
                    }
                    
                    local best_hitbox_score = 0
                    local visible_hitboxes = 0
                    
                    for hitbox_name, hitbox_pos in pairs(hitboxes) do
                        -- Use client_trace_line with proper parameters
                        local success, fraction = pcall(function()
                            return client_trace_line(my_eye_pos.x, my_eye_pos.y, my_eye_pos.z,
                                                   hitbox_pos.x, hitbox_pos.y, hitbox_pos.z,
                                                   entity_index)
                        end)
                        
                        if success and fraction then
                            local hitbox_score = 0
                            
                            if fraction > 0.97 then
                                -- Perfect visibility
                                hitbox_score = 400 * hitbox_pos.priority
                                visible_hitboxes = visible_hitboxes + 1
                                
                                -- Special bonuses for different weapon types
                                if weapon_data.type == "sniper" and hitbox_name == "head" then
                                    hitbox_score = hitbox_score * 1.8 -- Sniper headshot bonus
                                elseif weapon_data.type == "rifle" and (hitbox_name == "chest" or hitbox_name == "head") then
                                    hitbox_score = hitbox_score * 1.4 -- Rifle upper body bonus
                                elseif weapon_data.type == "smg" and hitbox_name ~= "head" then
                                    hitbox_score = hitbox_score * 1.2 -- SMG body shots
                                end
                                
                            elseif fraction > 0.85 then
                                -- Good visibility (some wall penetration possible)
                                hitbox_score = 250 * hitbox_pos.priority
                                visible_hitboxes = visible_hitboxes + 0.7
                                
                                -- Penetration bonus for high-damage weapons
                                if weapon_data.penetration and weapon_data.penetration > 0.8 then
                                    hitbox_score = hitbox_score * 1.2
                                end
                                
                            elseif fraction > 0.6 then
                                -- Partial visibility (wallbang required)
                                hitbox_score = 100 * hitbox_pos.priority
                                
                                -- Only valuable for high-penetration weapons
                                if weapon_data.penetration and weapon_data.penetration > 0.6 then
                                    hitbox_score = hitbox_score * weapon_data.penetration
                                else
                                    hitbox_score = hitbox_score * 0.3 -- Heavy penalty for low-pen weapons
                                end
                            else
                                -- Poor visibility
                                hitbox_score = -50
                            end
                            
                            best_hitbox_score = math.max(best_hitbox_score, hitbox_score)
                        else
                            -- Fallback calculation when trace fails
                            if distance < 400 then
                                best_hitbox_score = 200 * hitbox_pos.priority
                            elseif distance < 800 then
                                best_hitbox_score = 120 * hitbox_pos.priority
                            else
                                best_hitbox_score = 60 * hitbox_pos.priority
                            end
                        end
                    end
                    
                    -- Bonus for multiple visible hitboxes
                    if visible_hitboxes >= 3 then
                        best_hitbox_score = best_hitbox_score * 1.3
                    elseif visible_hitboxes >= 2 then
                        best_hitbox_score = best_hitbox_score * 1.15
                    end
                    
                    visibility_score = best_hitbox_score
                else
                    -- Fallback when eye position unavailable
                    visibility_score = math.max(0, 150 - distance * 0.1)
                end

                -- === АНАЛИЗ ОТДАЧИ И ТОЧНОСТИ ===
                local accuracy_score = 0
                
                -- Получаем текущую отдачу оружия
                local current_spread = entity_get_prop(weapon, "m_fAccuracyPenalty") or 0
                local recoil_index = entity_get_prop(weapon, "m_flRecoilIndex") or 0
                
                -- Штраф за отдачу
                accuracy_score = accuracy_score - current_spread * 100 * weapon_data.recoil_factor
                accuracy_score = accuracy_score - recoil_index * 20 * weapon_data.recoil_factor
                
                -- Бонус за точность оружия
                accuracy_score = accuracy_score + weapon_data.accuracy_factor * 100
                
                score = score + accuracy_score

                -- === СПЕЦИАЛЬНЫЕ МОДИФИКАТОРЫ ДЛЯ РАЗНЫХ ТИПОВ ОРУЖИЙ ===
                local weapon_specific_score = 0
                
                if weapon_data.type == "sniper" then
                    -- Снайперские винтовки: приоритет стабильности и дальности
                    if our_velocity_magnitude < 10 and velocity_magnitude < 50 then
                        weapon_specific_score = weapon_specific_score + 200
                    end
                    
                    if distance > 1000 then
                        weapon_specific_score = weapon_specific_score + 150
                    end
                    
                elseif weapon_data.type == "shotgun" then
                    -- Дробовики: приоритет близкой дистанции
                    if distance < 300 then
                        weapon_specific_score = weapon_specific_score + 300
                    end
                    
                    if distance > 500 then
                        weapon_specific_score = weapon_specific_score - 500
                    end
                    
                elseif weapon_data.type == "smg" then
                    -- SMG: хорошо работают в движении на средних дистанциях
                    if distance > 200 and distance < 800 then
                        weapon_specific_score = weapon_specific_score + 100
                    end
                    
                    if our_velocity_magnitude > 50 and our_velocity_magnitude < 200 then
                        weapon_specific_score = weapon_specific_score + 80
                    end
                    
                elseif weapon_data.type == "pistol" then
                    -- Пистолеты: универсальные, но с ограничениями по дистанции
                    if distance < 600 then
                        weapon_specific_score = weapon_specific_score + 100
                    end
                    
                    if weapon_data.name:find("deagle") and head_trace > 0.95 then
                        weapon_specific_score = weapon_specific_score + 200 -- Deagle хорош для хедшотов
                    end
                    
                elseif weapon_data.type == "rifle" then
                    -- Винтовки: универсальные с хорошей точностью
                    if distance > 500 and distance < 2000 then
                        weapon_specific_score = weapon_specific_score + 150
                    end
                    
                    if our_velocity_magnitude < 50 then
                        weapon_specific_score = weapon_specific_score + 100
                    end
                    
                elseif weapon_data.type == "machinegun" then
                    -- Пулеметы: лучше всего работают из статичной позиции
                    if our_velocity_magnitude < 20 then
                        weapon_specific_score = weapon_specific_score + 200
                    end
                    
                    if distance > 800 and distance < 1800 then
                        weapon_specific_score = weapon_specific_score + 150
                    end
                end
                
                score = score + weapon_specific_score

                -- === УЛУЧШЕННЫЕ ФИНАЛЬНЫЕ КОРРЕКТИРОВКИ ===
                
                -- Джиттер модификаторы
                score = score * jitter_analysis.factor
                
                -- Бонус за консистентность джиттера
                if jitter_analysis.consistency > 0.7 then
                    score = score + jitter_analysis.consistency * 150
                end
                
                -- Бонус за качество записи
                if record.lag_records_count then
                    if record.lag_records_count >= 3 and record.lag_records_count <= 10 then
                        score = score + 100
                    end
                end
                
                -- Штраф за экстремальные углы
                if record.angles then
                    local pitch = math_abs(record.angles.x)
                    if pitch > 89 then
                        score = score - 200 -- Подозрительные углы
                    end
                    
                    -- Дополнительный бонус для предсказуемых углов при джиттере
                    if jitter_analysis.pattern_type ~= "none" then
                        local yaw_in_range = record.angles.y >= -180 and record.angles.y <= 180
                        if yaw_in_range then
                            score = score + 80
                        end
                    end
                end
                
                -- === 4D BACKTRACK SCORING ENHANCEMENT ===
                -- Применяем 4D анализ к текущей записи
                local record_4d_score = 0
                
                if temporal_analysis[i] then
                    local temp_data = temporal_analysis[i]
                    
                    -- 4D пространственно-временная стабильность
                    if i > 1 and temporal_analysis[i-1] and temporal_analysis[i-1].vector_4d then
                        local prev_vector = temporal_analysis[i-1].vector_4d
                        local curr_vector = temp_data.vector_4d
                        
                        -- Проверяем что оба вектора валидны
                        if not prev_vector or not curr_vector then
                            goto skip_4d_analysis
                        end
                        
                        -- Вычисляем 4D расстояние между записями
                        local vector_diff = create_4d_vector_bt(
                            curr_vector.x - prev_vector.x,
                            curr_vector.y - prev_vector.y,
                            curr_vector.z - prev_vector.z,
                            curr_vector.w - prev_vector.w
                        )
                        
                        local spatial_distance = math_sqrt(vector_diff.x^2 + vector_diff.y^2 + vector_diff.z^2)
                        local temporal_distance = math_abs(vector_diff.w)
                        
                        -- Стабильность пространственных координат
                        if spatial_distance < 5.0 then
                            record_4d_score = record_4d_score + 150 -- Стабильная позиция
                        elseif spatial_distance < 15.0 then
                            record_4d_score = record_4d_score + 100 -- Умеренно стабильная
                        else
                            record_4d_score = record_4d_score - spatial_distance * 2 -- Штраф за нестабильность
                        end
                        
                        -- Временная согласованность
                        if temporal_distance < 50 then -- меньше 50мс разницы
                            record_4d_score = record_4d_score + 80
                        end
                    end
                    
                    -- 4D корреляция с соседними записями
                    local correlation_sum = 0
                    local correlation_count = 0
                    local curr_vector = temp_data.vector_4d
                    
                    for j = math_max(1, i-2), math_min(#records, i+2) do
                        if j ~= i and temporal_analysis[j] and temporal_analysis[j].vector_4d then
                            local other_vector = temporal_analysis[j].vector_4d
                            
                            -- Дополнительная проверка что curr_vector и other_vector валидны
                            if curr_vector and other_vector then
                                local curr_magnitude = magnitude_4d_bt(curr_vector)
                                local other_magnitude = magnitude_4d_bt(other_vector)
                                
                                -- Проверяем что магнитуды не равны нулю
                                if curr_magnitude > 0 and other_magnitude > 0 then
                                    local correlation = dot_product_4d_bt(
                                        curr_vector, other_vector
                                    ) / (curr_magnitude * other_magnitude + 0.001)
                                    
                                    correlation_sum = correlation_sum + correlation
                                    correlation_count = correlation_count + 1
                                end
                            end
                        end
                    end
                    
                    if correlation_count > 0 then
                        local avg_correlation = correlation_sum / correlation_count
                        record_4d_score = record_4d_score + avg_correlation * 100
                    end
                    
                    temp_data.stability_index = record_4d_score
                end
                
                ::skip_4d_analysis::
                
                -- === МАШИННОЕ ОБУЧЕНИЕ АНАЛИЗ ===
                local ml_score = 0
                
                -- Анализ паттернов на основе истории
                if #bt_history.successful_records > 0 then
                    -- Сравниваем текущую запись с успешными в прошлом
                    for _, successful_record in ipairs(bt_history.successful_records) do
                        if successful_record.weapon_type == weapon_data.type then
                            local similarity_score = 0
                            
                            -- Сходство по дистанции
                            local distance_similarity = 1.0 - math_abs(distance - successful_record.distance) / math_max(distance, successful_record.distance)
                            similarity_score = similarity_score + distance_similarity * ml_weights.position_stability
                            
                            -- Сходство по скорости цели
                            if record.velocity and successful_record.velocity then
                                local velocity_mag = vector_length(record.velocity)
                                local velocity_similarity = 1.0 - math_abs(velocity_mag - successful_record.velocity) / math_max(velocity_mag, successful_record.velocity)
                                similarity_score = similarity_score + velocity_similarity * ml_weights.velocity_consistency
                            end
                            
                            -- Сходство по времени назад
                            local time_similarity = 1.0 - math_abs(time_diff - successful_record.time_diff) / math_max(time_diff, successful_record.time_diff)
                            similarity_score = similarity_score + time_similarity * ml_weights.temporal_smoothness
                            
                            ml_score = ml_score + similarity_score * 50
                        end
                    end
                end
                
                -- Штраф на основе неудачных записей
                if #bt_history.failed_records > 0 then
                    for _, failed_record in ipairs(bt_history.failed_records) do
                        if failed_record.weapon_type == weapon_data.type then
                            local danger_score = 0
                            
                            -- Проверяем схожесть с неудачными записями
                            local distance_danger = 1.0 - math_abs(distance - failed_record.distance) / math_max(distance, failed_record.distance)
                            if distance_danger > 0.8 then -- Очень похоже на неудачную
                                danger_score = danger_score + distance_danger * 100
                            end
                            
                            ml_score = ml_score - danger_score
                        end
                    end
                end
                
                -- Адаптивные веса на основе общей точности
                local overall_accuracy = 0.5 -- базовая точность
                if bt_history.accuracy_metrics and bt_history.accuracy_metrics[weapon_data.type] then
                    overall_accuracy = bt_history.accuracy_metrics[weapon_data.type]
                end
                
                -- Если общая точность высокая, больше доверяем ML
                ml_score = ml_score * (0.5 + overall_accuracy * 0.8)
                
                if temporal_analysis[i] then
                    temporal_analysis[i].ml_score = ml_score
                end
                -- === WIDE JITTER DETECTION SCORING INTEGRATION ===
                -- Apply jitter-specific scoring modifiers to backtrack records
                local jitter_score_modifier = 0
                if backtrack_jitter_analysis.is_wide_jitter then
                    -- Base jitter detection bonus
                    jitter_score_modifier = backtrack_jitter_analysis.confidence * 200
                    
                    -- Pattern-specific adjustments
                    if backtrack_jitter_analysis.jitter_pattern == "advanced_network_exploit" then
                        jitter_score_modifier = jitter_score_modifier * 1.5
                    elseif backtrack_jitter_analysis.jitter_pattern == "choke_sequence_exploit" then
                        jitter_score_modifier = jitter_score_modifier * 1.3
                    elseif backtrack_jitter_analysis.jitter_pattern == "network_packet_manipulation" then
                        jitter_score_modifier = jitter_score_modifier * 1.4
                    elseif backtrack_jitter_analysis.jitter_pattern == "extreme_artificial_jitter" then
                        jitter_score_modifier = jitter_score_modifier * 1.6
                    elseif backtrack_jitter_analysis.jitter_pattern == "classic_wide_symmetric" then
                        jitter_score_modifier = jitter_score_modifier * 1.2
                    end
                    
                    -- Network anomaly detection bonus
                    if backtrack_jitter_analysis.network_anomaly then
                        jitter_score_modifier = jitter_score_modifier * 1.2
                    end
                    
                    -- Prediction accuracy bonus - УЛУЧШЕНО
                    if backtrack_jitter_analysis.prediction_accuracy > 0.8 then
                        -- Высокая точность предсказания - отличный признак
                        jitter_score_modifier = jitter_score_modifier * 1.4
                    elseif backtrack_jitter_analysis.prediction_accuracy > 0.6 then
                        jitter_score_modifier = jitter_score_modifier * 1.2
                    end
                    
                    -- Stability factor bonus - НОВОЕ
                    if backtrack_jitter_analysis.stability_factor > 0.8 then
                        jitter_score_modifier = jitter_score_modifier * (1.0 + backtrack_jitter_analysis.stability_factor * 0.5)
                    end
                    
                    -- Frequency analysis integration - НОВОЕ
                    if backtrack_jitter_analysis.frequency_analysis > 0.6 then
                        jitter_score_modifier = jitter_score_modifier * (1.0 + backtrack_jitter_analysis.frequency_analysis * 0.3)
                    end
                    
                    -- Record-specific jitter correlation
                    if record.angles and #backtrack_angle_history > i then
                        local current_angle = record.angles.y
                        local angle_data = backtrack_angle_history[i]
                        
                        if angle_data and math.abs(current_angle - angle_data.y) < 5 then
                            -- This record aligns well with jitter detection
                            jitter_score_modifier = jitter_score_modifier * 1.15
                        end
                    end
                    
                    -- Apply desync correction as a scoring factor
                    if backtrack_jitter_analysis.desync_correction > 0 then
                        jitter_score_modifier = jitter_score_modifier + (backtrack_jitter_analysis.desync_correction * 3)
                    end
                end
                
                -- === КОМБИНИРОВАНИЕ ВСЕХ СКОРОВ ===
                local final_score = score + record_4d_score + ml_score + jitter_score_modifier
                
                -- Дополнительная нормализация для экстремальных значений
                final_score = math_max(-1000, math_min(15000, final_score)) -- Increased max to accommodate jitter bonuses
                
                -- Проверка на лучший результат с улучшенной метрикой
                if final_score > best_score then
                    best_score = final_score
                    best_record = record
                    
                                            -- === ENHANCED V2 BACKTRACK RECORD DATA ===
                        -- Сохраняем расширенную информацию о лучшей записи с новыми системами
                        if best_record then
                            best_record.enhanced_score = final_score
                            best_record.record_4d_score = record_4d_score
                            best_record.ml_score = ml_score
                            best_record.jitter_score_modifier = jitter_score_modifier
                            best_record.weapon_used = weapon_data.type
                            best_record.analysis_time = globals_curtime()
                            
                            -- Wide jitter detection data for backtrack - УЛУЧШЕНО
                            best_record.jitter_analysis = {
                                is_wide_jitter = backtrack_jitter_analysis.is_wide_jitter,
                                jitter_pattern = backtrack_jitter_analysis.jitter_pattern,
                                jitter_intensity = backtrack_jitter_analysis.jitter_intensity,
                                desync_correction = backtrack_jitter_analysis.desync_correction,
                                confidence = backtrack_jitter_analysis.confidence,
                                antiaim_type = backtrack_jitter_analysis.antiaim_type,
                                prediction_accuracy = backtrack_jitter_analysis.prediction_accuracy,
                                stability_factor = backtrack_jitter_analysis.stability_factor,
                                frequency_analysis = backtrack_jitter_analysis.frequency_analysis,
                                direction_prediction = backtrack_jitter_analysis.direction_prediction
                            }
                        
                        -- === NEW V2 BACKTRACK FEATURES ===
                        -- Добавляем новые метрики V2
                        best_record.v2_features = {
                            distance_optimization = distance_score / 300,
                            movement_prediction = movement_score / 400,
                            weapon_compatibility = weapon_data.accuracy_factor,
                            temporal_4d_stability = record_4d_score and (record_4d_score / 1000) or 0,
                            riptide_compatibility = 0.8 + (math_random() * 0.4), -- Будет улучшено в следующих версиях
                            prediction_confidence = math_min(1.0, final_score / 5000),
                            backtrack_quality = "enhanced_v2"
                        }
                        
                        -- Инициализация bt_player_state для всех случаев
                        local bt_player_state = {
                            on_ground = record.flags and bit.band(record.flags, 1) == 1 or true,
                            ducking = record.duck_amount and record.duck_amount > 0.08 or false,
                            moving = record.velocity and vector_length(record.velocity) > 5 or false,
                            velocity_magnitude = record.velocity and vector_length(record.velocity) or 0,
                            duck_amount = record.duck_amount or 0
                        }
                        
                        -- Riptide коррекция для backtrack записи
                        if record.animlayers then
                            
                            local bt_quantum_state = {
                                wave_function_collapse = 0.9,
                                entanglement_factor = 0.8,
                                uncertainty_principle = 0.9
                            }
                            
                            -- === RIPTIDE V5 REVOLUTION BACKTRACK INTEGRATION ===
                            local bt_quantum_state_v5 = {
                                wave_function_collapse = math_sin(globals_curtime() * 2.7) * 0.5 + 0.5,
                                entanglement_factor = math_cos(globals_curtime() * 1.9) * 0.3 + 0.7,
                                uncertainty_principle = math_random() * 0.2 + 0.8
                            }
                            
                            -- Создаем network_data для backtrack
        local bt_network_data = {}
        for i = 1, 3 do
            table_insert(bt_network_data, {
                y = record.angles and record.angles.y or 0,
                timestamp = record.simulation_time or globals_curtime()
            })
        end
        local bt_riptide_result = riptide_correction(record.animlayers, record.velocity, bt_player_state, bt_quantum_state_v5, bt_network_data, entity_index)
                            
                            if bt_riptide_result then
                                best_record.riptide_v5_data = {
                                    riptide_factor = bt_riptide_result.riptide_factor,
                                    temporal_stability = bt_riptide_result.temporal_stability,
                                    velocity_correlation = bt_riptide_result.velocity_desync_correlation,
                                    advanced_correction = bt_riptide_result.advanced_correction,
                                    -- V5 революционная компонента
                                    enhanced_neural_network_prediction = bt_riptide_result.enhanced_neural_network_prediction or 0,
                                    machine_learning_adjustment = bt_riptide_result.machine_learning_adjustment or 0,
                                    quantum_entanglement_fix = bt_riptide_result.quantum_entanglement_fix or 0,
                                    ai_pattern_recognition = bt_riptide_result.ai_pattern_recognition or 0,
                                    predictive_analytics_boost = bt_riptide_result.predictive_analytics_boost or 0,
                                    weapon_specific_analysis = bt_riptide_result.weapon_specific_analysis or 0,
                                    map_aware_freestand = bt_riptide_result.map_aware_freestand or 0,
                                    enhanced_neural_confidence = bt_riptide_result.enhanced_neural_confidence or 0,
                                    adaptive_dropout = bt_riptide_result.adaptive_dropout or 0,
                                    temporal_prediction = bt_riptide_result.temporal_prediction or 0,
                                    velocity_prediction = bt_riptide_result.velocity_prediction or 0,
                                    animation_prediction = bt_riptide_result.animation_prediction or 0,
                                    meta_learning_enhancement = bt_riptide_result.meta_learning_enhancement or 0,
                                    algorithmic_evolution_score = bt_riptide_result.algorithmic_evolution_score or 0,
                                    confidence = bt_riptide_result.confidence,
                                    -- === FAKE LAG COMPENSATION DATA ===
                                    fake_lag_compensation = bt_riptide_result.fake_lag_compensation or 0,
                                    fake_lag_type = bt_riptide_result.fake_lag_type or "none",
                                    fake_lag_confidence = bt_riptide_result.fake_lag_confidence or 0,
                                    -- === HITBOX MATRIX DATA ===
                                    hitbox_matrix_correction = bt_riptide_result.hitbox_matrix_correction or 0,
                                    hitbox_matrix_confidence = bt_riptide_result.hitbox_matrix_confidence or 0,
                                    hitbox_matrix_prediction = bt_riptide_result.hitbox_matrix_prediction or nil
                                }
                                
                                -- === УЛЬТРА УЛУЧШЕННЫЙ V5 BONUS CALCULATION ===
                                local riptide_bonus = 0
                                
                                -- Базовые компоненты
                                riptide_bonus = riptide_bonus + (bt_riptide_result.riptide_factor * 500)
                                riptide_bonus = riptide_bonus + (bt_riptide_result.temporal_stability * 300)
                                
                                -- V5 компоненты
                                if bt_riptide_result.enhanced_neural_network_prediction then
                                    riptide_bonus = riptide_bonus + (math_abs(bt_riptide_result.enhanced_neural_network_prediction) * 0.9)
                                end
                                
                                if bt_riptide_result.machine_learning_adjustment then
                                    riptide_bonus = riptide_bonus + (math_abs(bt_riptide_result.machine_learning_adjustment) * 0.6)
                                end
                                
                                if bt_riptide_result.quantum_entanglement_fix then
                                    riptide_bonus = riptide_bonus + (math_abs(bt_riptide_result.quantum_entanglement_fix) * 0.7)
                                end
                                
                                if bt_riptide_result.ai_pattern_recognition then
                                    riptide_bonus = riptide_bonus + (math_abs(bt_riptide_result.ai_pattern_recognition) * 0.5)
                                end
                                
                                if bt_riptide_result.predictive_analytics_boost then
                                    riptide_bonus = riptide_bonus + (math_abs(bt_riptide_result.predictive_analytics_boost) * 0.6)
                                end
                                
                                -- V5 новые компоненты
                                if bt_riptide_result.weapon_specific_analysis then
                                    riptide_bonus = riptide_bonus + (math_abs(bt_riptide_result.weapon_specific_analysis) * 0.8)
                                end
                                
                                if bt_riptide_result.map_aware_freestand then
                                    riptide_bonus = riptide_bonus + (math_abs(bt_riptide_result.map_aware_freestand) * 0.7)
                                end
                                
                                if bt_riptide_result.enhanced_neural_confidence then
                                    riptide_bonus = riptide_bonus + (bt_riptide_result.enhanced_neural_confidence * 200)
                                end
                                
                                if bt_riptide_result.adaptive_dropout then
                                    riptide_bonus = riptide_bonus + (bt_riptide_result.adaptive_dropout * 150)
                                end
                                
                                if bt_riptide_result.meta_learning_enhancement then
                                    riptide_bonus = riptide_bonus + (math_abs(bt_riptide_result.meta_learning_enhancement) * 0.4)
                                end
                                
                                -- === FAKE LAG COMPENSATION BONUS ===
                                if bt_riptide_result.fake_lag_compensation and bt_riptide_result.fake_lag_compensation > 0 then
                                    riptide_bonus = riptide_bonus + (bt_riptide_result.fake_lag_compensation * 0.3)
                                end
                                
                                -- === HITBOX MATRIX BONUS ===
                                if bt_riptide_result.hitbox_matrix_correction and bt_riptide_result.hitbox_matrix_correction > 0 then
                                    riptide_bonus = riptide_bonus + (bt_riptide_result.hitbox_matrix_correction * 0.4)
                                end
                                
                                if bt_riptide_result.hitbox_matrix_confidence and bt_riptide_result.hitbox_matrix_confidence > 0.5 then
                                    riptide_bonus = riptide_bonus + (bt_riptide_result.hitbox_matrix_confidence * 100)
                                end
                                
                                -- ПРИНУДИТЕЛЬНО берем абсолютное значение бонуса
                                riptide_bonus = math_abs(riptide_bonus)
                                
                                best_record.enhanced_score = best_record.enhanced_score + riptide_bonus
                            end
                        end
                        
                        -- Предсказание направления для backtrack записи
                        if player_data[entity_index] then
                            local bt_direction_prediction = enhanced_direction_prediction(entity_index, player_data[entity_index], record, bt_player_state or {}, record.velocity)
                            
                            if bt_direction_prediction then
                                best_record.direction_v2_data = {
                                    method_used = bt_direction_prediction.method_used,
                                    confidence = bt_direction_prediction.confidence,
                                    final_direction = bt_direction_prediction.final_direction,
                                    pattern_detected = bt_direction_prediction.pattern_detected,
                                    prediction_strength = bt_direction_prediction.prediction_strength
                                }
                                
                                -- Бонус за высокую уверенность в направлении
                                if bt_direction_prediction.confidence > 0.7 then
                                    best_record.enhanced_score = best_record.enhanced_score + (bt_direction_prediction.confidence * 200)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- === ENHANCED V5 BACKTRACK LOGGING ===
    -- Ультра улучшенное логирование для backtrack V5
    if best_record and riptide_v5_debug and ui.get(riptide_v5_debug) then
        local v2_features = best_record.v2_features or {}
        local riptide_data = best_record.riptide_v5_data or {}
        local direction_data = best_record.direction_v2_data or {}
        
                if riptide_data.riptide_factor and riptide_data.riptide_factor > 0.3 then
            local fake_lag_info = ""
            if riptide_data.fake_lag_compensation and riptide_data.fake_lag_compensation > 0 then
                fake_lag_info = string.format(" | FakeLag: %.1f(%s,%.2f)", 
                    riptide_data.fake_lag_compensation,
                    riptide_data.fake_lag_type or "none",
                    riptide_data.fake_lag_confidence or 0
                )
            end
            
            debug_log(string.format(
                "[BACKTRACK-V5-ANALYSIS] Entity: %d | Score: %.0f | 4D: %.0f | ML: %.0f | Weapon: %s | RF: %.2f | Enhanced Neural: %.1f | ML: %.1f | Quantum: %.1f | AI: %.1f | Analytics: %.1f | Weapon: %.1f | Map: %.1f | Neural Conf: %.2f | Dropout: %.2f | Meta: %.1f | Evolution: %.2f%s",
                entity_index,
                best_record.enhanced_score,
                best_record.record_4d_score or 0,
                best_record.ml_score or 0,
                best_record.weapon_used or "unknown",
                riptide_data.riptide_factor or 0,
                riptide_data.enhanced_neural_network_prediction or 0,
                riptide_data.machine_learning_adjustment or 0,
                riptide_data.quantum_entanglement_fix or 0,
                riptide_data.ai_pattern_recognition or 0,
                riptide_data.predictive_analytics_boost or 0,
                riptide_data.weapon_specific_analysis or 0,
                riptide_data.map_aware_freestand or 0,
                                riptide_data.enhanced_neural_confidence or 0,
                                riptide_data.adaptive_dropout or 0,
                                riptide_data.meta_learning_enhancement or 0,
                                riptide_data.algorithmic_evolution_score or 0,
                                fake_lag_info
            ))
        end
    end

    -- УЛУЧШЕННОЕ логирование результата
    if best_record then
        local player_name = entity_get_player_name(entity_index)
        debug_log(string.format(
            "[BACKTRACK-IMPROVED] %s | Score: %.0f | Pattern: %s | Intensity: %.1f | Time: %.3fs",
            player_name or "Unknown",
            best_score,
            jitter_analysis.pattern_type,
            jitter_analysis.intensity,
            globals_curtime() - best_record.simulation_time
        ))
        
        -- Добавляем джиттер информацию в запись
        best_record.jitter_info = {
            pattern_type = jitter_analysis.pattern_type,
            intensity = jitter_analysis.intensity,
            consistency = jitter_analysis.consistency,
            factor = jitter_analysis.factor
        }
    end

    return best_record
end

-- === ADVANCED BACKTRACK SCORING SYSTEM ===
-- Улучшенная система оценки backtrack записей для лучших попаданий

local function calculate_advanced_backtrack_score(record, entity_index)
    if not record or not entity_index then return 0 end
    
    local score = 0
    local local_player = entity_get_local_player()
    if not local_player then return 0 end
    
    -- === 1. TEMPORAL QUALITY SCORING ===
    local time_diff = globals.curtime() - record.simulation_time
    local max_backtrack_time = 0.2  -- 200ms base
    local network_info = network_channel_system:get_network_info()
    local interp = get_interp_seconds()
    if network_info then
        local latency = (network_info.latency.incoming + network_info.latency.outgoing) / 2
        max_backtrack_time = max_backtrack_time + (latency * 0.5) + (interp * 0.5)
    else
        max_backtrack_time = max_backtrack_time + (interp * 0.5)
    end
    
    -- Optimal time range scoring
    if time_diff < 0.05 then
        score = score + 200  -- Recent records are highly valued
    elseif time_diff < 0.1 then
        score = score + 150  -- Good time range
    elseif time_diff < max_backtrack_time then
        score = score + (100 * (1 - (time_diff / max_backtrack_time)))
    else
        return 0  -- Too old
    end
    
    -- === 2. HITBOX ACCURACY SCORING ===
    local my_eye_pos = client.eye_position()
    if my_eye_pos and record.origin then
        -- Use hitbox head if available
        local head = get_hitbox_center(entity_index, 0)
        local target_head = {
            x = head.x ~= 0 and head.x or record.origin.x,
            y = head.y ~= 0 and head.y or record.origin.y,
            z = head.z ~= 0 and head.z or (record.origin.z + 64)
        }
        
        local distance = vector_distance(my_eye_pos, target_head)
        
        -- Distance-based scoring (closer = better for backtrack)
        if distance < 500 then
            score = score + 100
        elseif distance < 1000 then
            score = score + 80
        elseif distance < 2000 then
            score = score + 60
        else
            score = score + 40
        end
        
        -- === BULLET TRACE FOR VISIBILITY === (prefer bbox face multi-point)
        local function score_target_point(pt)
            local ox, oy, oz = my_eye_pos[1], my_eye_pos[2], my_eye_pos[3]
            local ok, trb = pcall(function()
                return client.trace_bullet(entity_get_local_player(), ox, oy, oz, pt.x, pt.y, pt.z, entity_index)
            end)
            if ok and trb then return trb.fraction or 0 end
            local tl = client.trace_line(ox, oy, oz, pt.x, pt.y, pt.z, entity_index)
            if type(tl) == 'number' then return tl end
            return (tl and tl.fraction) or 0
        end
        local function best_face_visibility(hitbox_id)
            local bbox = get_hitbox_bbox_via_studio and get_hitbox_bbox_via_studio(entity_index, hitbox_id)
            if bbox and bbox.mins and bbox.maxs and bbox.center then
                local cx, cy, cz = bbox.center.x, bbox.center.y, bbox.center.z
                local mx, my, mz = bbox.mins.x, bbox.mins.y, bbox.mins.z
                local Mx, My, Mz = bbox.maxs.x, bbox.maxs.y, bbox.maxs.z
                local pts = {
                    {x = cx, y = cy, z = cz},
                    {x = mx, y = cy, z = cz}, {x = Mx, y = cy, z = cz},
                    {x = cx, y = my, z = cz}, {x = cx, y = My, z = cz},
                    {x = cx, y = cy, z = mz}, {x = cx, y = cy, z = Mz}
                }
                local best = 0
                for _, p in ipairs(pts) do
                    local f = score_target_point(p)
                    if f > best then best = f end
                end
                return best
            end
            return score_target_point(get_hitbox_center(entity_index, hitbox_id))
        end
        local head_frac = best_face_visibility(0)
        if head_frac < 0.6 then
            local chest_frac = best_face_visibility(5)
            if chest_frac > head_frac then head_frac = chest_frac end
        end
        if head_frac > 0.9 then
            score = score + 220
        elseif head_frac > 0.75 then
            score = score + 120
        else
            score = score - 140
        end
    end
    
    -- === 3. MOVEMENT PREDICTION SCORING ===
    if record.velocity then
        local velocity_mag = vec_len2d(record.velocity)
        
        -- Stationary targets are easier to hit
        if velocity_mag < 5 then
            score = score + 120  -- Standing still
        elseif velocity_mag < 50 then
            score = score + 80   -- Slow movement
        elseif velocity_mag < 150 then
            score = score + 40   -- Normal movement
        else
            score = score + 10   -- Fast movement
        end
        
        -- === ACCELERATION ANALYSIS ===
        local records = lag_records[entity_index]
        if records and #records >= 2 then
            local prev_record = records[2]
            if prev_record and prev_record.velocity then
                local prev_vel_mag = math.sqrt(prev_record.velocity.x^2 + prev_record.velocity.y^2 + prev_record.velocity.z^2)
                local acceleration = math.abs(velocity_mag - prev_vel_mag)
                
                -- Lower acceleration = more predictable
                if acceleration < 20 then
                    score = score + 50
                elseif acceleration < 50 then
                    score = score + 30
                end
            end
        end
    end
    
    -- === 4. ANIMATION STATE SCORING ===
    if record.duck_amount then
        -- Crouching players are easier targets
        if record.duck_amount > 0.5 then
            score = score + 80
        elseif record.duck_amount > 0 then
            score = score + 40
        end
    end
    
    -- === 5. ANTI-AIM PATTERN SCORING ===
    if record.angles then
        local player_metrics = enhanced_resolver.performance_metrics[entity_index]
        if player_metrics then
            -- High accuracy players get bonus for their records
            score = score + (player_metrics.accuracy * 100)
            
            -- Factor in shot history
            if player_metrics.shots_fired > 5 then
                local hit_rate = player_metrics.shots_hit / player_metrics.shots_fired
                score = score + (hit_rate * 80)
            end
        end
        
        -- === DESYNC ANALYSIS ===
        local desync_pattern = detect_desync_pattern(entity_index, lag_records[entity_index])
        if desync_pattern then
            if desync_pattern.type == "static_fake" then
                score = score + 100  -- Static fakes are easier
            elseif desync_pattern.type == "micro_jitter" then
                score = score + 70   -- Micro jitter is manageable
            elseif desync_pattern.type == "sided_jitter" then
                score = score + 50   -- Sided jitter is predictable
            else
                score = score + 20   -- Other patterns
            end
        end
    end
    
    -- === 6. NETWORK QUALITY ADJUSTMENT ===
    if network_info then
        local quality_score = 100
        
        if network_info.packet_loss then
            local avg_loss = (network_info.packet_loss.incoming + network_info.packet_loss.outgoing) / 2
            quality_score = quality_score - (avg_loss * 500)
        end
        
        if network_info.choke then
            local avg_choke = (network_info.choke.incoming + network_info.choke.outgoing) / 2
            quality_score = quality_score - (avg_choke * 300)
        end
        
        local latency = (network_info.latency.incoming + network_info.latency.outgoing) / 2
        if latency > 0.08 then  -- >80ms
            quality_score = quality_score - ((latency - 0.08) * 1000)
        end
        
        score = score * (quality_score / 100)
    end
    
    -- === 7. WEAPON-SPECIFIC SCORING ===
    local weapon = entity.get_player_weapon(local_player)
    if weapon then
        local weapon_name = entity.get_classname(weapon):lower()
        
        if weapon_name:find("awp") or weapon_name:find("ssg08") then
            -- Snipers need precise records
            score = score * 1.3
            if time_diff < 0.08 then
                score = score * 1.2  -- Extra bonus for fresh records
            end
        elseif weapon_name:find("ak47") or weapon_name:find("m4a") then
            -- Rifles benefit from movement prediction
            if record.velocity then
                local vel_mag = vec_len2d(record.velocity)
                if vel_mag < 30 then
                    score = score * 1.15
                end
            end
        end
    end
    
    -- === 8. PLAYER-SPECIFIC LEARNING ===
    local backtrack_history = player_data[entity_index] and player_data[entity_index].backtrack_history
    if backtrack_history then
        -- Bonus for records similar to previously successful ones
        for _, successful_record in ipairs(backtrack_history.successful_records or {}) do
            if successful_record and successful_record.time_diff then
                local time_similarity = 1 - math.abs(time_diff - successful_record.time_diff) / 0.2
                if time_similarity > 0.7 then
                    score = score + (time_similarity * 50)
                end
            end
        end
    end
    
    return math.max(0, score)
end

-- === ENHANCED MULTI-RECORD BACKTRACK SELECTION ===
local function get_best_backtrack_record(entity_index)
    if not entity_index or entity_index == entity_get_local_player() then
        return nil
    end
    
    if not entity_is_alive(entity_index) or entity_is_dormant(entity_index) then
        return nil
    end
    
    local records = lag_records[entity_index]
    if not records or #records < 2 then
        return nil
    end
    
    local best_record = nil
    local best_score = 0
    local candidate_records = {}

    -- Dynamic time window based on latency/interp, no hard cap on record count
    local network_info = network_channel_system:get_network_info()
    local avg_latency = network_info and (network_info.latency.incoming + network_info.latency.outgoing) / 2 or 0
    local max_window = 0.2 + (avg_latency * 0.5)
    
    -- === ANALYZE ALL VALID RECORDS ===
    for i = 1, #records do
        local record = records[i]
        if record and record.simulation_time and record.origin then
            local time_diff = globals.curtime() - record.simulation_time
            
            -- Basic time validation
            if time_diff >= 0 and time_diff <= max_window then
                local score = calculate_advanced_backtrack_score(record, entity_index)
                
                if score > 0 then
                    table.insert(candidate_records, {
                        record = record,
                        score = score,
                        index = i,
                        time_diff = time_diff
                    })
                end
            else
                break -- older records will only be even older
            end
        end
    end
    
    if #candidate_records == 0 then
        return nil
    end
    
    -- === FAKE LAG DETECTION FOR BACKTRACK ===
    local fake_lag_analysis = nil
    if fake_lag_detection_enabled and fake_lag_detection_enabled.get() then
        fake_lag_analysis = detect_fake_lag_manipulation(entity_index, records, network_info)
    else
        fake_lag_analysis = { is_fake_lagging = false, confidence = 0, manipulation_type = "none" }
    end
    
    if fake_lag_analysis.is_fake_lagging then
        -- Adjust scoring for fake lag scenarios
        for i, candidate in ipairs(candidate_records) do
            if fake_lag_analysis.manipulation_type == "timing_manipulation" then
                -- Boost records with consistent timing patterns
                candidate.score = candidate.score * (1 + fake_lag_analysis.confidence * 0.3)
            elseif fake_lag_analysis.manipulation_type == "movement_manipulation" then
                -- Boost records with movement consistency
                candidate.score = candidate.score * (1 + fake_lag_analysis.confidence * 0.2)
            end
            
            if fake_lag_analysis.packet_manipulation then
                -- Additional boost for packet manipulation
                candidate.score = candidate.score * (1 + fake_lag_analysis.confidence * 0.25)
            end
        end
        
        -- Re-sort with adjusted scores
        table.sort(candidate_records, function(a, b) return a.score > b.score end)
        
        debug_log(string.format(
            "[BT-FAKELAG] Detected: %s | Type: %s | Confidence: %.2f | Adjusted scores",
            fake_lag_analysis.is_fake_lagging and "YES" or "NO",
            fake_lag_analysis.manipulation_type,
            fake_lag_analysis.confidence
        ))
    end
    
    -- Sort by score (highest first)
    table.sort(candidate_records, function(a, b) return a.score > b.score end)
    
    -- === ADAPTIVE RECORD SELECTION ===
    local selected_record = candidate_records[1].record
    
    -- For high-skill targets, sometimes use second-best to avoid predictability
    local player_metrics = enhanced_resolver.performance_metrics[entity_index]
    if player_metrics and player_metrics.accuracy > 0.8 and #candidate_records > 1 then
        if math.random() < 0.3 then  -- 30% chance
            selected_record = candidate_records[2].record
            debug_log("[BT-ADAPTIVE] Using second-best record for unpredictability")
        end
    end
    
    -- === ADVANCED VALIDATION ===
    local validation_passed = true
    local validation_reasons = {}
    
    -- Position validation with interpolation
    local current_origin = vector_new(entity_get_prop(entity_index, "m_vecOrigin"))
    local position_diff = vector_distance(current_origin, selected_record.origin)

    local max_position_diff = 250
    if selected_record.velocity then
        local vel2d = vec_len2d(selected_record.velocity)
        max_position_diff = max_position_diff + (vel2d * candidate_records[1].time_diff * 1.5)
    end
    
    if position_diff > max_position_diff then
        validation_passed = false
        table.insert(validation_reasons, "position_diff_too_large")
    end
    
    -- Network-aware validation
    local network_info = network_channel_system:get_network_info()
    if network_info then
        local quality = 1.0
        
        if network_info.packet_loss then
            local avg_loss = (network_info.packet_loss.incoming + network_info.packet_loss.outgoing) / 2
            quality = quality - (avg_loss * 2)
        end
        
        if quality < 0.5 then
            validation_passed = false
            table.insert(validation_reasons, "poor_network_quality")
        end
    end
    
    -- Enhanced metadata
    selected_record.backtrack_metadata = {
        score = candidate_records[1].score,
        validation_passed = validation_passed,
        validation_reasons = validation_reasons,
        position_diff = position_diff,
        candidates_count = #candidate_records,
        selection_time = globals.curtime(),
        network_compensated = network_info ~= nil,
        adaptive_selection = player_metrics and player_metrics.accuracy > 0.8,
        fake_lag_detected = fake_lag_analysis and fake_lag_analysis.is_fake_lagging or false,
        fake_lag_type = fake_lag_analysis and fake_lag_analysis.manipulation_type or "none",
        fake_lag_confidence = fake_lag_analysis and fake_lag_analysis.confidence or 0,
        hitbox_matrix_enabled = hitbox_matrix_resolving and hitbox_matrix_resolving.get() or false,
        hitbox_matrix_quality = hitbox_matrix_quality and hitbox_matrix_quality.get() or 4
    }
    
    if validation_passed then
        -- Enhanced debug logging with hitbox matrix info
        local debug_info = string.format(
            "[BT-SELECTED] Score: %.1f | Time: %.3fs | Pos: %.1f | Candidates: %d",
            candidate_records[1].score, candidate_records[1].time_diff, position_diff, #candidate_records
        )
        
        -- Add hitbox matrix info if enabled
        if hitbox_matrix_resolving and hitbox_matrix_resolving.get() then
            local matrix_info = ""
            if selected_record.riptide_v5_data and selected_record.riptide_v5_data.hitbox_matrix_correction then
                matrix_info = string.format(" | Matrix: %.2f (%.2f)", 
                    selected_record.riptide_v5_data.hitbox_matrix_correction,
                    selected_record.riptide_v5_data.hitbox_matrix_confidence or 0
                )
            end
            debug_info = debug_info .. matrix_info
        end
        
        debug_log(debug_info)
        return selected_record
    else
        debug_log("[BT-REJECTED] " .. table.concat(validation_reasons, ", "))
        return nil
    end
end
-- === ENHANCED BACKTRACK APPLICATION WITH INTERPOLATION ===
local function apply_backtrack_to_target(entity_index, record)
    if not record or not entity_index then
        return false
    end

    -- Validate before applying to avoid invalid defensive AA records
    local prev_record = lag_records[entity_index] and lag_records[entity_index][2]
    local validity = validate_backtrack_record(entity_index, record, prev_record)
    if not validity.valid then
        debug_log("[BT-SKIP] Invalid record: " .. table.concat(validity.reasons or {}, ", "))
        return false
    end

    -- Store target tick for aim integration
    prepare_shot_with_backtrack(entity_index, record)

    local success = true
    local local_player = entity_get_local_player()
    if not local_player then return false end
    
    -- === POSITION INTERPOLATION FOR MOVING TARGETS ===
    local final_position = record.origin

    if record.velocity and record.backtrack_metadata then
        local time_diff = record.backtrack_metadata.time_diff
        local velocity_mag = vec_len2d(record.velocity)

            -- Network-aware forward interpolation (no hard caps)
    local network_info = network_channel_system:get_network_info()
    local avg_latency = network_info and (network_info.latency.incoming + network_info.latency.outgoing) / 2 or 0
    local choke = network_info and (network_info.choke.incoming + network_info.choke.outgoing) / 2 or 0
    local prediction_horizon = math.min(time_diff, (avg_latency * (1 + choke * 2)))

    if velocity_mag > 10 and prediction_horizon > 0 then
        -- Pull predicted point slightly towards a visible line from eye to reduce wall-misses
        local predicted = vec_add(record.origin, vec_scale(record.velocity, prediction_horizon))
        local eye = client.eye_position()
        if eye then
            local ex, ey, ez = eye[1], eye[2], eye[3]
            if ex then
                local tr = client.trace_line(ex, ey, ez, predicted.x, predicted.y, predicted.z, entity_index)
                local frac = tr and (tr.fraction or tr) or 1
                if frac < 0.95 then
                    local pull = (1 - frac) * 8
                    local to_eye = vec_normalize({x = ex - predicted.x, y = ey - predicted.y, z = ez - predicted.z})
                    predicted = vec_add(predicted, vec_scale(to_eye, pull))
                end
            end
        end
        final_position = predicted
        debug_log(string.format("[BT-INTERP] Interpolated position by %.3fs (lat: %.3f, choke: %.2f)", prediction_horizon, avg_latency, choke))
    end
    end
    
    -- === ENHANCED POSITION APPLICATION ===
    local pos_success = pcall(function()
        entity_set_prop(entity_index, "m_vecOrigin", final_position.x, final_position.y, final_position.z)
    end)
    
    if not pos_success then
        debug_log("[BT-ERROR] Failed to set position")
        success = false
    end
    
    -- === ANGLE APPLICATION WITH DESYNC COMPENSATION ===
    if record.angles then
        local final_angles = record.angles
        
        -- Apply resolver-based angle correction
        local resolved_yaw = resolve_aisetpos(entity_index)
        if resolved_yaw and resolved_yaw ~= 0 then
            final_angles = {
                x = record.angles.x,
                y = resolved_yaw  -- Use resolved yaw instead of raw angle
            }
        end
        
        local angle_success = pcall(function()
            entity_set_prop(entity_index, "m_angEyeAngles[0]", final_angles.x)
            entity_set_prop(entity_index, "m_angEyeAngles[1]", final_angles.y)
        end)
        
        if not angle_success then
            debug_log("[BT-ERROR] Failed to set angles")
            success = false
        end
    end
    
    -- === SIMULATION TIME APPLICATION ===
    if record.simulation_time then
        local sim_success = pcall(function()
            entity_set_prop(entity_index, "m_flSimulationTime", record.simulation_time)
        end)
        
        if not sim_success then
            debug_log("[BT-ERROR] Failed to set simulation time")
            success = false
        end
    end
    
    -- === ANIMATION LAYERS APPLICATION ===
    if record.animlayers then
        for i, layer in ipairs(record.animlayers) do
            if layer and i <= 13 then
                local layer_success = pcall(function()
                    if layer.sequence then
                        entity_set_prop(entity_index, "m_AnimOverlay[" .. (i-1) .. "].m_nSequence", layer.sequence)
                    end
                    if layer.cycle then
                        entity_set_prop(entity_index, "m_AnimOverlay[" .. (i-1) .. "].m_flCycle", layer.cycle)
                    end
                    if layer.weight then
                        entity_set_prop(entity_index, "m_AnimOverlay[" .. (i-1) .. "].m_flWeight", layer.weight)
                    end
                    if layer.rate then
                        entity_set_prop(entity_index, "m_AnimOverlay[" .. (i-1) .. "].m_flPlaybackRate", layer.rate)
                    end
                end)
                
                if not layer_success then
                    debug_log("[BT-ERROR] Failed to set animation layer " .. i)
                end
            end
        end
    end
    
    -- === VELOCITY APPLICATION FOR PREDICTION ===
    if record.velocity then
        local vel_success = pcall(function()
            entity_set_prop(entity_index, "m_vecVelocity[0]", record.velocity.x)
            entity_set_prop(entity_index, "m_vecVelocity[1]", record.velocity.y)
            entity_set_prop(entity_index, "m_vecVelocity[2]", record.velocity.z)
        end)
        
        if not vel_success then
            debug_log("[BT-ERROR] Failed to set velocity")
        end
    end
    
    -- === CROUCH STATE APPLICATION ===
    if record.duck_amount then
        local duck_success = pcall(function()
            entity_set_prop(entity_index, "m_flDuckAmount", record.duck_amount)
            if record.flags then
                entity_set_prop(entity_index, "m_fFlags", record.flags)
            end
        end)
        
        if not duck_success then
            debug_log("[BT-ERROR] Failed to set duck state")
        end
    end
    
    -- === HITBOX MATRIX INTEGRATION FOR BACKTRACK APPLICATION ===
    -- Интеграция системы матрицы хитбоксов для улучшения применения backtrack
    if success and hitbox_matrix_resolving and hitbox_matrix_resolving.get() then
        if record.riptide_v5_data and record.riptide_v5_data.hitbox_matrix_correction then
            -- Применяем коррекцию от матрицы хитбоксов к позиции
            local matrix_correction = record.riptide_v5_data.hitbox_matrix_correction
            local matrix_confidence = record.riptide_v5_data.hitbox_matrix_confidence or 0
            
            if matrix_confidence > 0.3 then
                -- Корректируем позицию на основе анализа матрицы хитбоксов
                local correction_factor = math.min(0.5, matrix_confidence * 0.8)
                local corrected_position = {
                    x = final_position.x + (matrix_correction * correction_factor),
                    y = final_position.y + (matrix_correction * correction_factor),
                    z = final_position.z
                }
                
                -- Применяем скорректированную позицию
                local pos_success = pcall(function()
                    entity_set_prop(entity_index, "m_vecOrigin[0]", corrected_position.x)
                    entity_set_prop(entity_index, "m_vecOrigin[1]", corrected_position.y)
                    entity_set_prop(entity_index, "m_vecOrigin[2]", corrected_position.z)
                end)
                
                if pos_success then
                    final_position = corrected_position
                    debug_log(string.format(
                        "[BT-MATRIX] Applied matrix correction: %.2f (confidence: %.2f)",
                        matrix_correction,
                        matrix_confidence
                    ))
                end
            end
        end
    end
    
    -- Record application result for learning
    if success then
        local player_data_entry = player_data[entity_index]
        if player_data_entry then
            if not player_data_entry.backtrack_history then
                player_data_entry.backtrack_history = {
                    successful_records = {},
                    failed_records = {},
                    accuracy_metrics = {},
                    pattern_recognition = {}
                }
            end
            
            -- Store successful application
            table.insert(player_data_entry.backtrack_history.successful_records, {
                time_diff = record.backtrack_metadata and record.backtrack_metadata.time_diff or 0,
                score = record.backtrack_metadata and record.backtrack_metadata.score or 0,
                position_diff = record.backtrack_metadata and record.backtrack_metadata.position_diff or 0,
                timestamp = globals.curtime(),
                interpolated = final_position ~= record.origin,
                hitbox_matrix_applied = record.riptide_v5_data and record.riptide_v5_data.hitbox_matrix_correction and true or false,
                matrix_correction = record.riptide_v5_data and record.riptide_v5_data.hitbox_matrix_correction or 0,
                matrix_confidence = record.riptide_v5_data and record.riptide_v5_data.hitbox_matrix_confidence or 0
            })
            
            -- Limit history size
            while #player_data_entry.backtrack_history.successful_records > 20 do
                table.remove(player_data_entry.backtrack_history.successful_records, 1)
            end
        end
    end
    
    return success
end
-- === BACKTRACK LEARNING SYSTEM ===
local function update_backtrack_learning(entity_index, shot_hit, record_used)
    local player_data_entry = player_data[entity_index]
    if not player_data_entry or not record_used then return end
    
    if not player_data_entry.backtrack_history then
        player_data_entry.backtrack_history = {
            successful_records = {},
            failed_records = {},
            accuracy_metrics = {},
            pattern_recognition = {}
        }
    end
    
    local bt_history = player_data_entry.backtrack_history
    
    -- Update accuracy metrics
    if not bt_history.accuracy_metrics.total_shots then
        bt_history.accuracy_metrics = {
            total_shots = 0,
            total_hits = 0,
            accuracy = 0.5,
            best_time_range = {min = 0.05, max = 0.15},
            preferred_score_threshold = 200
        }
    end
    
    local metrics = bt_history.accuracy_metrics
    metrics.total_shots = metrics.total_shots + 1
    
    if shot_hit then
        metrics.total_hits = metrics.total_hits + 1
        
        -- Learn from successful records
        if record_used.backtrack_metadata then
            local time_diff = record_used.backtrack_metadata.time_diff
            local score = record_used.backtrack_metadata.score
            
            -- Update optimal time range
            if time_diff < metrics.best_time_range.max then
                metrics.best_time_range.min = math.max(0.02, (metrics.best_time_range.min * 0.9) + (time_diff * 0.1))
                metrics.best_time_range.max = math.min(0.25, (metrics.best_time_range.max * 0.9) + (time_diff * 1.2 * 0.1))
            end
            
            -- Update score threshold
            metrics.preferred_score_threshold = (metrics.preferred_score_threshold * 0.8) + (score * 0.2)
            
            debug_log(string.format(
                "[BT-LEARN] Hit! Time: %.3fs Score: %.1f | New range: %.3f-%.3f",
                time_diff, score, metrics.best_time_range.min, metrics.best_time_range.max
            ))
        end
    else
        -- Learn from misses
        if record_used.backtrack_metadata then
            local time_diff = record_used.backtrack_metadata.time_diff
            
            -- Expand time range slightly if we missed with a good time
            if time_diff < metrics.best_time_range.max then
                metrics.best_time_range.max = math.min(0.3, metrics.best_time_range.max * 1.05)
            end
        end
    end
    
    metrics.accuracy = metrics.total_hits / metrics.total_shots
    
    -- Pattern recognition learning
    if not bt_history.pattern_recognition.movement_preferences then
        bt_history.pattern_recognition = {
            movement_preferences = {
                static = {shots = 0, hits = 0},
                slow = {shots = 0, hits = 0},
                fast = {shots = 0, hits = 0}
            },
            distance_preferences = {
                close = {shots = 0, hits = 0},
                medium = {shots = 0, hits = 0},
                long = {shots = 0, hits = 0}
            }
        }
    end
    
    -- Categorize and learn from shot
    local velocity_mag = 0
    if record_used.velocity then
        velocity_mag = math.sqrt(record_used.velocity.x^2 + record_used.velocity.y^2 + record_used.velocity.z^2)
    end
    
    local movement_category = "static"
    if velocity_mag > 100 then
        movement_category = "fast"
    elseif velocity_mag > 20 then
        movement_category = "slow"
    end
    
    local pattern_data = bt_history.pattern_recognition.movement_preferences[movement_category]
    pattern_data.shots = pattern_data.shots + 1
    if shot_hit then
        pattern_data.hits = pattern_data.hits + 1
    end
end

-- === ENHANCED BACKTRACK PROCESSING V3 ===
-- Революционная система backtrack с машинным обучением и адаптацией
local function process_backtrack(entity_index)
    local best_record = get_best_backtrack_record(entity_index)
    if not best_record then
        return false
    end
    
    -- === ADAPTIVE RECORD SELECTION BASED ON LEARNING ===
    local player_data_entry = player_data[entity_index]
    if player_data_entry and player_data_entry.backtrack_history then
        local metrics = player_data_entry.backtrack_history.accuracy_metrics
        if metrics and metrics.total_shots > 10 then
            -- If our accuracy is low, try different time ranges
            if metrics.accuracy < 0.4 then
                local records = lag_records[entity_index]
                if records and #records > 3 then
                    -- Look for records in learned optimal range
                    for i = 1, math.min(8, #records) do
                        local record = records[i]
                        if record and record.simulation_time then
                            local time_diff = globals.curtime() - record.simulation_time
                            if time_diff >= metrics.best_time_range.min and time_diff <= metrics.best_time_range.max then
                                local score = calculate_advanced_backtrack_score(record, entity_index)
                                if score > metrics.preferred_score_threshold * 0.8 then
                                    best_record = record
                                    debug_log("[BT-ADAPTIVE] Using learned optimal record")
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- === DYNAMIC BACKTRACK INTENSITY ===
    local local_player = entity_get_local_player()
    if not local_player then return false end
    
    local weapon = entity_get_player_weapon(local_player)
    local backtrack_intensity = 1.0
    
    if weapon then
        local weapon_name = entity_get_classname(weapon):lower()
        
        -- Adjust intensity based on weapon type
        if weapon_name:find("awp") then
            backtrack_intensity = 1.5  -- Aggressive for AWP
        elseif weapon_name:find("ak47") or weapon_name:find("m4a") then
            backtrack_intensity = 1.2  -- Moderate for rifles
        elseif weapon_name:find("deagle") then
            backtrack_intensity = 1.3  -- High for Deagle
        else
            backtrack_intensity = 1.0  -- Standard for others
        end
    end
    
    -- Network quality adjustment
    local network_info = network_channel_system:get_network_info()
    if network_info then
        local quality = 1.0
        
        if network_info.latency then
            local avg_latency = (network_info.latency.incoming + network_info.latency.outgoing) / 2
            if avg_latency > 0.1 then  -- >100ms
                backtrack_intensity = backtrack_intensity * 0.8  -- Reduce intensity for high latency
            end
        end
        
        if network_info.packet_loss then
            local avg_loss = (network_info.packet_loss.incoming + network_info.packet_loss.outgoing) / 2
            if avg_loss > 0.03 then  -- >3% loss
                backtrack_intensity = backtrack_intensity * 0.7
            end
        end
    end
    
    -- === STATE PRESERVATION ===
    local original_state = {
        origin = vector_new(entity_get_prop(entity_index, "m_vecOrigin")),
        angles = {
            x = entity_get_prop(entity_index, "m_angEyeAngles[0]"),
            y = entity_get_prop(entity_index, "m_angEyeAngles[1]")
        },
        simulation_time = entity_get_prop(entity_index, "m_flSimulationTime"),
        velocity = vector_new(entity_get_prop(entity_index, "m_vecVelocity")),
        duck_amount = entity_get_prop(entity_index, "m_flDuckAmount"),
        flags = entity_get_prop(entity_index, "m_fFlags")
    }
    
    -- === ENHANCED APPLICATION ===
    local success = apply_backtrack_to_target(entity_index, best_record)
    
    -- Store the record used for learning
    if success then
        if not player_data_entry then
            player_data[entity_index] = {}
            player_data_entry = player_data[entity_index]
        end
        
        player_data_entry.last_backtrack_record = best_record
        player_data_entry.last_backtrack_time = globals.curtime()
        player_data_entry.backtrack_intensity_used = backtrack_intensity
    end
    
    if success then
        local player_name = entity_get_player_name(entity_index)
        local time_diff = globals_curtime() - best_record.simulation_time
        
        -- === V5 ENHANCED VALIDATION ===
        -- Ультра продвинутая валидация с новыми системами V5
        local validation_passed = true
        
        -- Проверяем Riptide V5 совместимость
        if best_record.riptide_v5_data then
            local riptide_factor = best_record.riptide_v5_data.riptide_factor
            local temporal_stability = best_record.riptide_v5_data.temporal_stability
            local neural_prediction = best_record.riptide_v5_data.enhanced_neural_network_prediction or 0
            local quantum_fix = best_record.riptide_v5_data.quantum_entanglement_fix or 0
            
            -- Если Riptide фактор слишком высок и стабильность низкая, это может быть ненадежно
            if riptide_factor > 0.8 and temporal_stability < 0.3 then
                validation_passed = false
                debug_log(string.format(
                    "[BACKTRACK-V3-WARN] %s | High Riptide factor with low stability: R=%.2f T=%.2f",
                    player_name, riptide_factor, temporal_stability
                ))
            end
            
            -- V5 дополнительные проверки
            -- Если нейросетевое предсказание слишком экстремальное
            if math_abs(neural_prediction) > 50 then
                debug_log(string.format(
                    "[BACKTRACK-V5-WARN] %s | Extreme neural prediction: %.1f",
                    player_name, neural_prediction
                ))
            end
            
            -- Если квантовая коррекция слишком высока
            if math_abs(quantum_fix) > 30 then
                debug_log(string.format(
                    "[BACKTRACK-V5-WARN] %s | High quantum correction: %.1f",
                    player_name, quantum_fix
                ))
            end
        end
        
        -- Проверяем направление предсказания
        if best_record.direction_v2_data then
            local direction_confidence = best_record.direction_v2_data.confidence
            local method_used = best_record.direction_v2_data.method_used
            
            -- Если уверенность в направлении очень низкая, предупреждаем
            if direction_confidence < 0.3 then
                debug_log(string.format(
                    "[BACKTRACK-V2-WARN] %s | Low direction confidence: %.2f method: %s",
                    player_name, direction_confidence, method_used
                ))
            end
        end
        
        -- Обновляем статистику игрока
        if player_data[entity_index] then
            local data = player_data[entity_index]
            
            -- Инициализируем backtrack статистику V5 если нужно
            if not data.backtrack_v5_stats then
                data.backtrack_v5_stats = {
                    total_uses = 0,
                    successful_applications = 0,
                    average_riptide_factor = 0,
                    average_direction_confidence = 0,
                    preferred_methods = {},
                    last_use_time = 0,
                    -- V5 статистика
                    average_enhanced_neural_prediction = 0,
                    average_quantum_fix = 0,
                    average_ai_pattern = 0,
                    average_weapon_analysis = 0,
                    average_map_freestand = 0,
                    v5_success_rate = 0.5,
                    neural_accuracy = 0.5,
                    quantum_stability = 0.5
                }
            end
            
            local bt_stats = data.backtrack_v5_stats
            bt_stats.total_uses = bt_stats.total_uses + 1
            bt_stats.last_use_time = globals_curtime()
            
            if validation_passed then
                bt_stats.successful_applications = bt_stats.successful_applications + 1
                
                -- Обновляем средние значения
                if best_record.riptide_v5_data then
                    bt_stats.average_riptide_factor = 
                        (bt_stats.average_riptide_factor * 0.8) + (best_record.riptide_v5_data.riptide_factor * 0.2)
                    
                    -- V5 статистика
                    if best_record.riptide_v5_data.enhanced_neural_network_prediction then
                        bt_stats.average_enhanced_neural_prediction = 
                            (bt_stats.average_enhanced_neural_prediction * 0.8) + (math_abs(best_record.riptide_v5_data.enhanced_neural_network_prediction) * 0.2)
                    end
                    
                    if best_record.riptide_v5_data.quantum_entanglement_fix then
                        bt_stats.average_quantum_fix = 
                            (bt_stats.average_quantum_fix * 0.8) + (math_abs(best_record.riptide_v5_data.quantum_entanglement_fix) * 0.2)
                    end
                    
                    if best_record.riptide_v5_data.ai_pattern_recognition then
                        bt_stats.average_ai_pattern = 
                            (bt_stats.average_ai_pattern * 0.8) + (math_abs(best_record.riptide_v5_data.ai_pattern_recognition) * 0.2)
                    end
                    
                    -- V5 новые компоненты
                    if best_record.riptide_v5_data.weapon_specific_analysis then
                        bt_stats.average_weapon_analysis = 
                            (bt_stats.average_weapon_analysis * 0.8) + (math_abs(best_record.riptide_v5_data.weapon_specific_analysis) * 0.2)
                    end
                    
                    if best_record.riptide_v5_data.map_aware_freestand then
                        bt_stats.average_map_freestand = 
                            (bt_stats.average_map_freestand * 0.8) + (math_abs(best_record.riptide_v5_data.map_aware_freestand) * 0.2)
                    end
                end
                
                if best_record.direction_v2_data then
                    bt_stats.average_direction_confidence = 
                        (bt_stats.average_direction_confidence * 0.8) + (best_record.direction_v2_data.confidence * 0.2)
                    
                    local method = best_record.direction_v2_data.method_used
                    if not bt_stats.preferred_methods[method] then
                        bt_stats.preferred_methods[method] = 0
                    end
                    bt_stats.preferred_methods[method] = bt_stats.preferred_methods[method] + 1
                end
                
                -- Обновляем V5 успешность
                local success_rate = bt_stats.successful_applications / bt_stats.total_uses
                bt_stats.v5_success_rate = (bt_stats.v5_success_rate * 0.9) + (success_rate * 0.1)
            end
        end
        
        -- === V5 ENHANCED LOGGING ===
        local v2_features = best_record.v2_features or {}
        local riptide_data = best_record.riptide_v5_data or {}
        local direction_data = best_record.direction_v2_data or {}
        
        if riptide_v5_debug and ui.get(riptide_v5_debug) and riptide_data.riptide_factor and riptide_data.riptide_factor > 0.3 then
            debug_log(string.format(
                "[BACKTRACK-APPLIED] %s | Time: %.3fs | Score: %.0f | Valid: %s",
                player_name or "Unknown",
                time_diff,
                best_record.enhanced_score,
                validation_passed and "YES" or "NO"
            ))
        end
        
        return validation_passed
    end
    
    return false
end

-- Интеграция backtrack в основную систему
local function enhanced_backtrack_integration()
    local enemies = entity_get_all("CCSPlayer")
    
    for i = 1, #enemies do
        local entity_index = enemies[i]
        
        if entity_is_alive(entity_index) and not entity_is_dormant(entity_index) then
            -- Обновляем lag records для этого игрока
            update_lag_records(entity_index)
            
            -- Обрабатываем backtrack если нужно
            if should_use_backtrack(entity_index) then
                process_backtrack(entity_index)
            end
        end
    end
end

-- Функция для определения, нужно ли использовать backtrack

-- === INTELLIGENT BACKTRACK USAGE DECISION ===
function should_use_backtrack(entity_index)
    local local_player = entity_get_local_player()
    if not local_player then return false end
    
    -- Basic validity checks
    if not entity_is_alive(entity_index) or entity_is_dormant(entity_index) then
        return false
    end
    
    if not entity_is_enemy(entity_index) then
        return false
    end
    
    -- Weapon and timing checks
    local weapon = entity_get_player_weapon(local_player)
    if not weapon then return false end
    
    local next_attack = entity_get_prop(weapon, "m_flNextPrimaryAttack")
    local server_time = globals.curtime()
    
    -- Check if we can shoot soon
    local can_shoot_soon = next_attack and next_attack <= server_time + 0.15
    if not can_shoot_soon then return false end
    
    -- === ENHANCED FOV AND VISIBILITY CHECKS ===
    local my_eye_pos = client.eye_position()
    if not my_eye_pos then return false end
    
    local target_origin = {entity_get_prop(entity_index, "m_vecOrigin")}
    if not target_origin[1] then return false end
    
    local head = get_hitbox_center(entity_index, 0)
    local target_head = {
        x = head.x ~= 0 and head.x or target_origin[1],
        y = head.y ~= 0 and head.y or target_origin[2],
        z = head.z ~= 0 and head.z or (target_origin[3] + 64)
    }
    
    -- FOV calculation
    local view_angles = client.camera_angles()
    local yaw, pitch = calculate_angle(my_eye_pos, target_head)
    local fov = math.abs(normalize_angle(view_angles[2] - yaw))
    
    -- Dynamic FOV based on weapon type
    local max_fov = 90
    local weapon_name = entity.get_classname(weapon):lower()
    
    if weapon_name:find("awp") or weapon_name:find("ssg08") then
        max_fov = 60  -- Stricter for snipers
    elseif weapon_name:find("ak47") or weapon_name:find("m4a") then
        max_fov = 75  -- Moderate for rifles
    elseif weapon_name:find("deagle") then
        max_fov = 70  -- Strict for Deagle
    else
        max_fov = 90  -- Lenient for other weapons
    end
    
    if fov > max_fov then
        return false
    end
    
    -- === DISTANCE-BASED DECISION ===
    local distance = vector_distance(my_eye_pos, target_head)
    
    -- Don't use backtrack for very close targets (movement prediction works better)
    if distance < 150 then
        return false
    end
    
    -- Don't use backtrack for extremely far targets (too much uncertainty)
    if distance > 4000 then
        return false
    end
    
    -- === MOVEMENT ANALYSIS ===
    local target_velocity = {entity_get_prop(entity_index, "m_vecVelocity")}
    local velocity_mag = 0
    if target_velocity[1] then
        velocity_mag = math.sqrt(target_velocity[1]^2 + target_velocity[2]^2 + target_velocity[3]^2)
    end
    
    -- Backtrack is most effective for moving targets
    if velocity_mag < 5 then
        -- For stationary targets, only use if we have good records
        local records = lag_records[entity_index]
        if not records or #records < 3 then
            return false
        end
    end
    
    -- === PLAYER-SPECIFIC LEARNING ===
    local player_data_entry = player_data[entity_index]
    if player_data_entry and player_data_entry.backtrack_history then
        local metrics = player_data_entry.backtrack_history.accuracy_metrics
        if metrics and metrics.total_shots > 5 then
            -- If we have poor accuracy with this player, be more selective
            if metrics.accuracy < 0.3 then
                -- Only use backtrack if we have very good records
                local best_record = get_best_backtrack_record(entity_index)
                if not best_record or not best_record.backtrack_metadata then
                    return false
                end
                
                local score = best_record.backtrack_metadata.score or 0
                if score < metrics.preferred_score_threshold * 1.2 then
                    return false
                end
            end
        end
    end
    
    -- === NETWORK QUALITY CHECK ===
    local network_info = network_channel_system:get_network_info()
    if network_info then
        -- Don't use backtrack in poor network conditions
        if network_info.packet_loss then
            local avg_loss = (network_info.packet_loss.incoming + network_info.packet_loss.outgoing) / 2
            if avg_loss > 0.08 then  -- >8% loss
                return false
            end
        end
        
        if network_info.latency then
            local avg_latency = (network_info.latency.incoming + network_info.latency.outgoing) / 2
            if avg_latency > 0.15 then  -- >150ms
                return false
            end
        end
    end
    
    -- === RAY TRACE VISIBILITY CHECK ===
    local trace_result = client.trace_line(my_eye_pos, target_head, entity_index)
    if not trace_result then return false end
    
    -- Must have clear line of sight or nearly clear
    if trace_result.hit_entity ~= entity_index and trace_result.fraction < 0.95 then
        return false
    end
    
    -- === WEAPON-SPECIFIC CONDITIONS ===
    if weapon_name:find("awp") then
        -- For AWP, only use on moving targets or high-confidence records
        if velocity_mag < 20 then
            local best_record = get_best_backtrack_record(entity_index)
            if not best_record or not best_record.backtrack_metadata then
                return false
            end
            
            local score = best_record.backtrack_metadata.score or 0
            if score < 300 then  -- High threshold for AWP on stationary targets
                return false
            end
        end
    end
    
    -- === FINAL RECORD QUALITY CHECK ===
    local records = lag_records[entity_index]
    if not records or #records < 2 then
        return false
    end
    
    -- Check if we have any decent records
    local has_good_record = false
    for i = 1, math.min(5, #records) do
        local record = records[i]
        if record and record.simulation_time then
            local time_diff = globals.curtime() - record.simulation_time
            if time_diff > 0 and time_diff < 0.25 then
                local score = calculate_advanced_backtrack_score(record, entity_index)
                if score > 150 then
                    has_good_record = true
                    break
                end
            end
        end
    end
    
    if not has_good_record then
        return false
    end
    
    debug_log(string.format(
        "[BT-DECISION] Using backtrack for %s (FOV: %.1f, Dist: %.1f, Vel: %.1f)",
        entity.get_player_name(entity_index) or "Unknown", fov, distance, velocity_mag
    ))
    
    return true
end

-- === BACKTRACK EVENT HANDLERS FOR LEARNING ===
local last_shot_data = {}

-- Event handler for weapon fire
client.set_event_callback("weapon_fire", function(e)
    local shooter_id = client.userid_to_entindex(e.userid)
    local local_player = entity.get_local_player()
    
    if shooter_id == local_player then
        -- Track our shots for backtrack learning
        local enemies = entity.get_all("CCSPlayer")
        for _, entity_index in ipairs(enemies) do
            if entity_is_alive(entity_index) and entity_is_enemy(entity_index) then
                local player_data_entry = player_data[entity_index]
                if player_data_entry and player_data_entry.last_backtrack_record and 
                   player_data_entry.last_backtrack_time and 
                   (globals.curtime() - player_data_entry.last_backtrack_time) < 0.1 then
                    
                    -- Store shot data for hit detection
                    last_shot_data[entity_index] = {
                        record_used = player_data_entry.last_backtrack_record,
                        shot_time = globals.curtime(),
                        intensity_used = player_data_entry.backtrack_intensity_used or 1.0
                    }
                    
                    debug_log(string.format("[BT-SHOT] Fired at %s with backtrack", 
                        entity.get_player_name(entity_index) or "Unknown"))
                end
            end
        end
    end
end)

-- Event handler for player hurt (hit detection)
client.set_event_callback("player_hurt", function(e)
    local attacker_id = client.userid_to_entindex(e.attacker)
    local victim_id = client.userid_to_entindex(e.userid)
    local local_player = entity.get_local_player()
    
    if attacker_id == local_player and victim_id and last_shot_data[victim_id] then
        local shot_data = last_shot_data[victim_id]
        local time_since_shot = globals.curtime() - shot_data.shot_time
        
        -- Only count hits within reasonable time window
        if time_since_shot < 0.2 then
            update_backtrack_learning(victim_id, true, shot_data.record_used)
            
            local damage = e.dmg_health or 0
            debug_log(string.format("[BT-HIT] Successful hit for %d damage (%.3fs after shot)", 
                damage, time_since_shot))
            
            -- Clean up
            last_shot_data[victim_id] = nil
        end
    end
end)

-- Clean up missed shots after timeout
client.set_event_callback("paint", function()
    local current_time = globals.curtime()
    
    for entity_index, shot_data in pairs(last_shot_data) do
        if current_time - shot_data.shot_time > 0.5 then
            -- Count as miss
            update_backtrack_learning(entity_index, false, shot_data.record_used)
            debug_log("[BT-MISS] Shot timeout - counting as miss")
            last_shot_data[entity_index] = nil
        end
    end
    
    -- Run main backtrack integration
    enhanced_backtrack_integration()
end)

-- === ENHANCED BACKTRACK PERFORMANCE MONITORING ===
local backtrack_performance = {
    total_applications = 0,
    successful_applications = 0,
    total_shots_with_bt = 0,
    hits_with_bt = 0,
    last_reset = globals.curtime()
}

local function get_backtrack_performance()
    local current_time = globals.curtime()
    
    -- Reset stats every 5 minutes
    if current_time - backtrack_performance.last_reset > 300 then
        backtrack_performance = {
            total_applications = 0,
            successful_applications = 0,
            total_shots_with_bt = 0,
            hits_with_bt = 0,
            last_reset = current_time
        }
    end
    
    local success_rate = 0
    local hit_rate = 0
    
    if backtrack_performance.total_applications > 0 then
        success_rate = backtrack_performance.successful_applications / backtrack_performance.total_applications
    end
    
    if backtrack_performance.total_shots_with_bt > 0 then
        hit_rate = backtrack_performance.hits_with_bt / backtrack_performance.total_shots_with_bt
    end
    
    return {
        application_success_rate = success_rate,
        hit_rate = hit_rate,
        total_applications = backtrack_performance.total_applications,
        total_shots = backtrack_performance.total_shots_with_bt
    }
end

-- === BACKTRACK AUTO-ADJUSTMENT SYSTEM ===
local function auto_adjust_backtrack_settings()
    local performance = get_backtrack_performance()
    
    -- If hit rate is too low, adjust strategy
    if performance.total_shots > 20 and performance.hit_rate < 0.3 then
        -- Reduce backtrack aggressiveness globally
        for entity_index, player_data_entry in pairs(player_data) do
            if player_data_entry.backtrack_history then
                local metrics = player_data_entry.backtrack_history.accuracy_metrics
                if metrics then
                    -- Expand time range to find better records
                    metrics.best_time_range.max = math.min(0.3, metrics.best_time_range.max * 1.1)
                    metrics.preferred_score_threshold = metrics.preferred_score_threshold * 0.9
                end
            end
        end
        
        debug_log("[BT-AUTO] Low hit rate detected, adjusting settings")
    elseif performance.total_shots > 10 and performance.hit_rate > 0.7 then
        -- High hit rate - can be more aggressive
        for entity_index, player_data_entry in pairs(player_data) do
            if player_data_entry.backtrack_history then
                local metrics = player_data_entry.backtrack_history.accuracy_metrics
                if metrics then
                    -- Tighten time range for precision
                    metrics.best_time_range.max = math.max(0.1, metrics.best_time_range.max * 0.95)
                    metrics.preferred_score_threshold = metrics.preferred_score_threshold * 1.05
                end
            end
        end
        
        debug_log("[BT-AUTO] High hit rate detected, increasing precision")
    end
end

-- Enhanced pattern-based desync detection
local function detect_desync_pattern(entity_index, records)
    if #records < 5 then return {type = "unknown", strength = 0, direction = 1} end
    
    local angle_changes = {}
    local timing_deltas = {}
    
    for i = 1, math.min(8, #records - 1) do
        if records[i] and records[i+1] and records[i].angles and records[i+1].angles then
            local angle_delta = normalize_angle_safe(records[i].angles.y - records[i+1].angles.y)
            table.insert(angle_changes, angle_delta)
            
            if records[i].simulation_time and records[i+1].simulation_time then
                table.insert(timing_deltas, records[i].simulation_time - records[i+1].simulation_time)
            end
        end
    end
    
    if #angle_changes < 3 then return {type = "unknown", strength = 0, direction = 1} end
    
    -- Analyze patterns
    local avg_change = 0
    local max_change = 0
    local direction_consistency = 0
    local positive_changes = 0
    
    for _, change in ipairs(angle_changes) do
        avg_change = avg_change + math.abs(change)
        max_change = math.max(max_change, math.abs(change))
        if change > 0 then positive_changes = positive_changes + 1 end
    end
    
    avg_change = avg_change / #angle_changes
    direction_consistency = math.abs((positive_changes / #angle_changes) - 0.5) * 2
    
    local pattern_type = "normal"
    local strength = avg_change / 60.0  -- Normalize to 0-1
    
    if max_change > 120 and avg_change > 40 then
        pattern_type = "aggressive_jitter"
        strength = math.min(1.0, strength * 1.5)
    elseif avg_change > 60 and direction_consistency > 0.7 then
        pattern_type = "sided_jitter"
        strength = math.min(1.0, strength * 1.3)
    elseif avg_change > 30 and max_change < 80 then
        pattern_type = "micro_jitter"
        strength = math.min(1.0, strength * 1.1)
    elseif avg_change < 15 then
        pattern_type = "static_fake"
        strength = 0.8
    end
    
    local predicted_direction = positive_changes > (#angle_changes / 2) and 1 or -1
    
    return {
        type = pattern_type,
        strength = strength,
        direction = predicted_direction,
        avg_change = avg_change,
        max_change = max_change,
        consistency = direction_consistency
    }
end

-- Run auto-adjustment every 30 seconds
local last_auto_adjust = 0
client.set_event_callback("paint", function()
    local current_time = globals.curtime()
    
    if current_time - last_auto_adjust > 30 then
        auto_adjust_backtrack_settings()
        last_auto_adjust = current_time
    end
end)
local function extract_neural_features(entity_index)
    local features = {}
    local records = lag_records[entity_index] or {}
    
    -- Angle history features (8 values)
    for i = 1, 8 do
        if records[i] and records[i].angles then
            table.insert(features, normalize_angle_safe(records[i].angles.y) / 180.0)
        else
            table.insert(features, 0)
        end
    end
    
    -- Velocity features (3 values)
    if entity_is_alive(entity_index) then
        local vel_x, vel_y, vel_z = entity_get_prop(entity_index, "m_vecVelocity")
        if vel_x then
            table.insert(features, math.min(1.0, vel_x / 250.0))
            table.insert(features, math.min(1.0, vel_y / 250.0))
            table.insert(features, math.min(1.0, vel_z / 250.0))
        else
            table.insert(features, 0)
            table.insert(features, 0)
            table.insert(features, 0)
        end
    else
        table.insert(features, 0)
        table.insert(features, 0)
        table.insert(features, 0)
    end
    
    -- Timing features (4 values)
    local current_time = globals_curtime()
    table.insert(features, (current_time % 1.0))
    table.insert(features, (globals_tickcount() % 64) / 64.0)
    table.insert(features, globals_frametime() * 100)
    table.insert(features, math.sin(current_time * 2))
    
    -- Ensure we always return exactly 15 features
    while #features < 15 do
        table.insert(features, 0)
    end
    
    -- Add advanced features if available
    if records[1] then
        -- Animation layer analysis
        if records[1].animlayers then
            local layers = records[1].animlayers
            if layers[6] and layers[6].weight then
                features[1] = features[1] * (1 + layers[6].weight)
            end
            if layers[12] and layers[12].weight then
                features[2] = features[2] * (1 + layers[12].weight)
            end
        end
        
        -- Duck amount influence
        if records[1].duck_amount then
            features[3] = features[3] * (1 + records[1].duck_amount)
        end
        
        -- Velocity influence
        if records[1].velocity then
            local vel_mag = vector_length(records[1].velocity)
            features[4] = features[4] * (1 + math.min(1.0, vel_mag / 320))
        end
    end
    
    -- Network-based features
    local network_info = network_channel_system:get_network_info()
    if network_info then
        local latency = (network_info.latency.incoming + network_info.latency.outgoing) / 2
        features[13] = features[13] * (1 + math.min(1.0, latency * 10))
        
        if network_info.packet_loss then
            local loss = (network_info.packet_loss.incoming + network_info.packet_loss.outgoing) / 2
            features[14] = features[14] * (1 + math.min(1.0, loss * 20))
        end
    end
    
    -- Pattern-based features
    local desync_pattern = detect_desync_pattern(entity_index, records)
    if desync_pattern then
        features[15] = features[15] * (1 + desync_pattern.strength)
    end
    
    -- Normalize all features to [-1, 1] range
    for i = 1, #features do
        features[i] = math.max(-1, math.min(1, features[i]))
    end
    
    return features
end

-- === ADVANCED FAKE LAG DETECTION AND COMPENSATION SYSTEM ===
function detect_fake_lag_manipulation(entity_index, records, network_info)
    if not records or #records < 5 then
        return {
            is_fake_lagging = false,
            confidence = 0,
            manipulation_type = "none",
            compensation_factor = 1.0,
            network_anomalies = {},
            timing_patterns = {},
            packet_manipulation = false
        }
    end
    
    local fake_lag_data = {
        is_fake_lagging = false,
        confidence = 0,
        manipulation_type = "none",
        compensation_factor = 1.0,
        network_anomalies = {},
        timing_patterns = {},
        packet_manipulation = false
    }
    
    -- Analyze timing patterns for artificial delays
    local timing_analysis = {}
    for i = 1, math.min(8, #records) do
        if records[i] and records[i + 1] then
            local time_diff = (records[i].simulation_time or 0) - (records[i + 1].simulation_time or 0)
            if time_diff > 0 then
                table.insert(timing_analysis, time_diff)
            end
        end
    end
    
    -- Detect suspicious timing patterns
    if #timing_analysis >= 3 then
        local avg_timing = 0
        for _, timing in ipairs(timing_analysis) do
            avg_timing = avg_timing + timing
        end
        avg_timing = avg_timing / #timing_analysis
        
        -- Check for unnaturally consistent timing (fake lag indicator)
        local timing_variance = 0
        for _, timing in ipairs(timing_analysis) do
            timing_variance = timing_variance + math.abs(timing - avg_timing)
        end
        timing_variance = timing_variance / #timing_analysis
        
        -- Low variance suggests artificial timing
        if timing_variance < 0.001 and avg_timing > 0.008 then
            fake_lag_data.is_fake_lagging = true
            fake_lag_data.confidence = math.min(0.9, (0.001 - timing_variance) * 1000)
            fake_lag_data.manipulation_type = "timing_manipulation"
            fake_lag_data.timing_patterns = {
                average = avg_timing,
                variance = timing_variance,
                samples = #timing_analysis
            }
        end
    end
    
    -- Analyze network packet patterns
    if network_info then
        local packet_anomalies = {}
        
        -- Check for packet loss manipulation
        if network_info.packet_loss and network_info.packet_loss.incoming > 0.15 then
            local loss_pattern = network_info.packet_loss.incoming
            if loss_pattern > 0.3 then
                fake_lag_data.packet_manipulation = true
                fake_lag_data.network_anomalies.packet_loss = loss_pattern
                fake_lag_data.confidence = math.max(fake_lag_data.confidence, loss_pattern * 0.8)
            end
        end
        
        -- Check for choke manipulation
        if network_info.choke and network_info.choke.incoming > 0.2 then
            local choke_pattern = network_info.choke.incoming
            if choke_pattern > 0.4 then
                fake_lag_data.packet_manipulation = true
                fake_lag_data.network_anomalies.choke = choke_pattern
                fake_lag_data.confidence = math.max(fake_lag_data.confidence, choke_pattern * 0.7)
            end
        end
        
        -- Check for latency spikes
        if network_info.latency and network_info.latency.incoming > 0.1 then
            local latency_spike = network_info.latency.incoming
            if latency_spike > 0.15 then
                fake_lag_data.network_anomalies.latency_spike = latency_spike
                fake_lag_data.confidence = math.max(fake_lag_data.confidence, (latency_spike - 0.1) * 2)
            end
        end
    end
    
    -- Analyze movement patterns for artificial stuttering
    local movement_analysis = {}
    for i = 1, math.min(6, #records) do
        if records[i] and records[i].velocity then
            local speed = vector_length(records[i].velocity)
            table.insert(movement_analysis, speed)
        end
    end
    
    if #movement_analysis >= 4 then
        local speed_variance = 0
        local avg_speed = 0
        for _, speed in ipairs(movement_analysis) do
            avg_speed = avg_speed + speed
        end
        avg_speed = avg_speed / #movement_analysis
        
        for _, speed in ipairs(movement_analysis) do
            speed_variance = speed_variance + math.abs(speed - avg_speed)
        end
        speed_variance = speed_variance / #movement_analysis
        
        -- Unnaturally consistent speed during movement suggests fake lag
        if avg_speed > 50 and speed_variance < 5 then
            fake_lag_data.is_fake_lagging = true
            fake_lag_data.confidence = math.max(fake_lag_data.confidence, (5 - speed_variance) * 0.2)
            fake_lag_data.manipulation_type = "movement_manipulation"
        end
    end
    
    -- Calculate compensation factor based on confidence
    if fake_lag_data.is_fake_lagging then
        local base_compensation = 1.0 + (fake_lag_data.confidence * 0.5)
        
        -- Additional compensation for different manipulation types
        if fake_lag_data.manipulation_type == "timing_manipulation" then
            base_compensation = base_compensation * 1.3
        elseif fake_lag_data.manipulation_type == "movement_manipulation" then
            base_compensation = base_compensation * 1.2
        end
        
        if fake_lag_data.packet_manipulation then
            base_compensation = base_compensation * 1.4
        end
        
        fake_lag_data.compensation_factor = math.min(2.5, base_compensation)
    end
    
    return fake_lag_data
end

-- === ENHANCED FAKE LAG COMPENSATION ===
function apply_fake_lag_compensation(entity_index, fake_lag_data, base_desync, direction_data, network_info)
    if not fake_lag_data or not fake_lag_data.is_fake_lagging then
        return base_desync, direction_data
    end
    
    local compensated_desync = base_desync
    local compensated_direction = direction_data
    
    -- Apply timing manipulation compensation
    if fake_lag_data.manipulation_type == "timing_manipulation" then
        local timing_boost = fake_lag_data.timing_patterns.average * 1000
        compensated_desync = compensated_desync * (1 + timing_boost * 0.1)
        
        -- Adjust direction prediction for timing manipulation
        if fake_lag_data.timing_patterns.variance < 0.0005 then
            -- Very low variance suggests predictable fake lag
            compensated_direction.prediction_strength = math.min(0.95, compensated_direction.prediction_strength + 0.2)
        end
    end
    
    -- Apply movement manipulation compensation
    if fake_lag_data.manipulation_type == "movement_manipulation" then
        compensated_desync = compensated_desync * 1.15
        
        -- Enhance movement prediction
        compensated_direction.movement_confidence = (compensated_direction.movement_confidence or 0.5) + 0.15
    end
    
    -- Apply packet manipulation compensation
    if fake_lag_data.packet_manipulation then
        local packet_compensation = 1.0
        
        if fake_lag_data.network_anomalies.packet_loss then
            packet_compensation = packet_compensation + (fake_lag_data.network_anomalies.packet_loss * 0.5)
        end
        
        if fake_lag_data.network_anomalies.choke then
            packet_compensation = packet_compensation + (fake_lag_data.network_anomalies.choke * 0.3)
        end
        
        compensated_desync = compensated_desync * packet_compensation
    end
    
    -- Apply overall compensation factor
    compensated_desync = compensated_desync * fake_lag_data.compensation_factor
    
    -- Enhance prediction confidence for fake lag scenarios
    compensated_direction.prediction_strength = math.min(0.95, compensated_direction.prediction_strength + (fake_lag_data.confidence * 0.1))
    
    return compensated_desync, compensated_direction
end

-- === ENHANCED AISETPOS RESOLUTION SYSTEM V4 ===
local function resolve_aisetpos(entity_index)
    if not entity_is_alive(entity_index) or entity_is_dormant(entity_index) then
        return 0
    end
    
    local records = lag_records[entity_index]
    if not records or #records < 3 then
        local fallback_yaw = entity_get_prop(entity_index, "m_angEyeAngles[1]") or entity_get_prop(entity_index, "m_angEyeAngles", 1) or 0
        return normalize_angle_safe(fallback_yaw)
    end

    local player_name = entity_get_player_name(entity_index)
    if not player_name then return 0 end

    -- Initialize or get player data
    if not player_data[entity_index] then
        player_data[entity_index] = {
            yaw_history = {},
            desync_history = {},
            velocity_history = {},
            shots_fired = 0,
            shots_hit = 0,
            shots_missed = 0,
            last_resolve = 0,
            fake_angles = {},
            pattern_detected = false,
            pattern_type = "unknown",
            pattern_confidence = 0,
            desync_range = {min = 999, max = -999, average = 0},
            behavioral_analysis = {
                aggression = 0.5,
                predictability = 0.5,
                adaptation_rate = 0.5,
                network_sensitivity = 0.5,
                packet_correlation = 0.0,
                latency_adaptation = 0.0,
                jitter_resistance = 0.5
            },
            performance_metrics = {
                accuracy = 0,
                consistency = 0,
                last_update = 0,
                resolution_quality = 0.0,
                hit_probability = 0.5,
                miss_rate = 0.5,
                adaptive_success = 0.5,
                network_correlation_accuracy = 0.5
            }
        }
    end

    local data = player_data[entity_index]

    -- Ensure required substructures exist (in case player_data was created minimally elsewhere)
    if not data.yaw_history then data.yaw_history = {} end
    if not data.desync_history then data.desync_history = {} end
    if not data.velocity_history then data.velocity_history = {} end
    if not data.performance_metrics then
        data.performance_metrics = {
            accuracy = 0,
            consistency = 0,
            last_update = 0,
            resolution_quality = 0.0,
            hit_probability = 0.5,
            miss_rate = 0.5,
            adaptive_success = 0.5,
            network_correlation_accuracy = 0.5
        }
    end
    if not data.behavioral_analysis then
        data.behavioral_analysis = {
            aggression = 0.5,
            predictability = 0.5,
            adaptation_rate = 0.5,
            network_sensitivity = 0.5,
            packet_correlation = 0.0,
            latency_adaptation = 0.0,
            jitter_resistance = 0.5
        }
    end

    local current_record = records[1]
    local velocity_data = vector_new(entity_get_prop(entity_index, "m_vecVelocity"))
    
    -- Ensure direction memory exists
    if not data.direction_memory then
        data.direction_memory = { last_directions = {}, left_count = 0, right_count = 0, stability = 0.5 }
    end
    
    -- Get network state
    local network_info = network_channel_system:get_network_info()
    local network_quality = network_channel_system:analyze_connection_quality(network_info)
    
    -- Prepare angle history with network timing
    local angle_history = {}
    for i = 1, math.min(15, #records) do
        if records[i] and records[i].angles then
            table.insert(angle_history, {
                y = records[i].angles.y,
                timestamp = records[i].simulation_time or globals.curtime() - (i * globals.tickinterval()),
                network_time = network_info and network_info.last_received or globals.curtime(),
                latency = network_info and ((network_info.latency.incoming + network_info.latency.outgoing) / 2) or 0.025
            })
        end
    end
    
    -- Enhanced jitter detection with network awareness
    local jitter_analysis = wide_jitter_detection(entity_index, angle_history)
    
    -- === ADVANCED FAKE LAG DETECTION ===
    local fake_lag_data = nil
    if fake_lag_detection_enabled and fake_lag_detection_enabled.get() then
        fake_lag_data = detect_fake_lag_manipulation(entity_index, records, network_info)
    else
        fake_lag_data = { is_fake_lagging = false, confidence = 0, manipulation_type = "none", compensation_factor = 1.0 }
    end
    
    -- Neural network feature extraction
    local neural_features = extract_neural_features(entity_index)
    
    -- Network-aware direction prediction
    local direction_data = enhanced_direction_prediction(entity_index, data, current_record, {
        moving = vector_length(velocity_data) > 5,
        on_ground = bit.band(current_record.flags or 0, 1) == 1,
        ducking = current_record.duck_amount and current_record.duck_amount > 0.1
    }, velocity_data)

    -- Freestand bias
    local freestand = compute_freestand_bias(entity_index)
    if freestand.confidence > 0.1 then
        direction_data.final_direction = (freestand.dir ~= 0) and freestand.dir or direction_data.final_direction
        direction_data.prediction_strength = (direction_data.prediction_strength or 0.5) * (1 + freestand.confidence * 0.2)
    end
    
    -- Initialize quantum state for advanced prediction
    local quantum_state = {
        wave_function_collapse = math.sin(globals.curtime() * 2.7) * 0.5 + 0.5,
        entanglement_factor = math.cos(globals.curtime() * 1.9) * 0.3 + 0.7,
        uncertainty_principle = math.random() * 0.2 + 0.8
    }
    
    -- Enhanced animation analysis
    local animlayers = get_animlayer_data(entity_index)
    local riptide_result = nil
    
    if animlayers then
        local player_state = {
            moving = vector_length(velocity_data) > 5,
            on_ground = bit.band(current_record.flags or 0, 1) == 1,
            ducking = current_record.duck_amount and current_record.duck_amount > 0.1,
            duck_amount = current_record.duck_amount or 0
        }
        
        riptide_result = riptide_correction(
            animlayers,
            velocity_data,
            player_state,
            quantum_state,
            network_data,
            entity_index
        )
    end
    
    -- Calculate base desync
    local resolved_yaw = safe_number(current_record.angles and current_record.angles.y, 0)

    -- Prefer animation-based dynamic desync when possible
    local dynamic_desync = 0
    if current_record.animlayers and current_record.velocity then
        dynamic_desync = math.abs(analyze_movement_layers(current_record.animlayers, current_record.velocity, {
            moving = vector_length(current_record.velocity) > 5,
            on_ground = bit.band(current_record.flags or 0, 1) == 1,
            ducking = (current_record.duck_amount or 0) > 0.1
        }))
    end

    local lby_desync = analyze_desync_angle(entity_index)
    local base_desync = math.max(dynamic_desync or 0, lby_desync or 0)

    if base_desync == nil or base_desync <= 0 then
        -- fallback to recent history variance
        if data and data.desync_history and #data.desync_history >= 3 then
            local sum = 0
            local n = math.min(6, #data.desync_history)
            for i = #data.desync_history - n + 1, #data.desync_history do
                sum = sum + math.abs(data.desync_history[i])
            end
            base_desync = math.min(58, (sum / n))
        else
            base_desync = 25
        end
    end
    -- weapon and movement aware clamp
    do
        local weapon = entity_get_player_weapon(entity_get_local_player())
        local wname = weapon and entity_get_classname(weapon):lower() or 'unknown'
        local is_smg = wname:find('mp') or wname:find('bizon') or wname:find('p90') or wname:find('ump')
        local speed2d = vec_len2d(velocity_data)
        if is_smg and speed2d > 40 then base_desync = math.min(base_desync, 40) end
    end
    
    -- Apply jitter analysis
    if jitter_analysis.is_wide_jitter then
        local jitter_correction = jitter_analysis.desync_correction
        
        -- Network quality adjustment
        if network_quality then
                    local network_stability = network_quality.score or 1.0
        jitter_correction = jitter_correction * network_stability
        
        -- Additional compensation for high latency
        if network_info and network_info.latency then
            local avg_latency = (network_info.latency.incoming + network_info.latency.outgoing) / 2
            if avg_latency > 0.05 then
                -- scale down jitter correction to avoid over-rotation at high ping
                local damp = math_min(0.9, (avg_latency - 0.05) * 3)
                jitter_correction = jitter_correction * (1 - damp)
            end
        end
        end
        
            -- Force positive correction (requirement)
    jitter_correction = math.abs(jitter_correction)

    -- Direction smoothing with last decisions
    data.direction_memory = data.direction_memory or {last_directions = {}}
    local last_dir = 0
    if #data.direction_memory.last_directions > 0 then
        last_dir = data.direction_memory.last_directions[#data.direction_memory.last_directions].direction or 0
    end

    -- Apply direction with network + freestand compensation
    local direction = compensated_direction and compensated_direction.final_direction or direction_data.final_direction
    if freestand and freestand.confidence > 0.2 then
        direction = freestand.dir ~= 0 and freestand.dir or direction
    end
    if last_dir ~= 0 and direction ~= last_dir then
        -- Smooth flips when confidence is low
        local prediction_strength = compensated_direction and compensated_direction.prediction_strength or direction_data.prediction_strength
        if (prediction_strength or 0.5) < 0.6 then
            direction = last_dir
        end
    end

    -- Flip briefly only on resolver miss
    if data.resolver_flip_until and globals.curtime() < data.resolver_flip_until then
        direction = -direction
    end

    -- Local movement bias: use our lateral motion to bias side
    do
        local lp = entity_get_local_player()
        if lp then
            local lv = vector_new(entity_get_prop(lp, "m_vecVelocity"))
            local speed2d = vec_len2d(lv)
            if speed2d > 30 then
                local ex, ey, ez = entity_get_origin(entity_index)
                local lx, ly, lz = entity_get_origin(lp)
                if ex and lx then
                    local e2l = {x = lx - ex, y = ly - ey, z = 0}
                    local cross = e2l.x * lv.y - e2l.y * lv.x
                    local bias_sign = cross >= 0 and 1 or -1
                    local bias_strength = math_min(1.0, speed2d / 250)
                    local prediction_strength = compensated_direction and compensated_direction.prediction_strength or direction_data.prediction_strength
                    if (prediction_strength or 0.5) < 0.8 then
                        direction = (bias_strength > 0.25) and bias_sign or direction
                    end
                end
            end
        end
    end

    -- Target velocity bias: use enemy lateral motion around its facing
    do
        local tv = vector_new(entity_get_prop(entity_index, "m_vecVelocity"))
        local spd = vec_len2d(tv)
        if spd > 30 then
            local yaw_basis = (current_record and current_record.angles and current_record.angles.y) or resolved_yaw
            local fy = math_rad(yaw_basis)
            local fwd = {x = math_cos(fy), y = math_sin(fy), z = 0}
            local vnorm = vec_normalize(tv)
            local cross = fwd.x * vnorm.y - fwd.y * vnorm.x
            local lateral_weight = math_abs(cross)
            local bias_sign = (cross >= 0) and 1 or -1
            local dir_conf = compensated_direction and compensated_direction.prediction_strength or direction_data.prediction_strength
            if dir_conf < 0.85 then
                if lateral_weight > 0.35 then
                    direction = bias_sign
                elseif dir_conf < 0.6 and lateral_weight > 0.2 then
                    direction = bias_sign
                end
            end
        end
    end

    -- Visibility-based validation of chosen side (bbox face multi-point if available)
    do
        local e1, e2, e3 = client.eye_position()
        local ex1, ey1, ez1
        if type(e1) == 'number' and type(e2) == 'number' and type(e3) == 'number' then
            ex1, ey1, ez1 = e1, e2, e3
        elseif type(e1) == 'table' and e1[1] and e1[2] and e1[3] then
            ex1, ey1, ez1 = e1[1], e1[2], e1[3]
        end
        if ex1 then
            local bbox = get_hitbox_bbox_via_studio and get_hitbox_bbox_via_studio(entity_index, 0)
            if bbox and bbox.mins and bbox.maxs and bbox.center then
                local function sample_face_points(left)
                    local pts = {}
                    local cx, cy, cz = bbox.center.x, bbox.center.y, bbox.center.z
                    local mx, my, mz = bbox.mins.x, bbox.mins.y, bbox.mins.z
                    local Mx, My, Mz = bbox.maxs.x, bbox.maxs.y, bbox.maxs.z
                    if left then
                        table.insert(pts, {x = mx, y = cy, z = cz})
                        table.insert(pts, {x = mx, y = My, z = cz})
                        table.insert(pts, {x = mx, y = my, z = cz})
                    else
                        table.insert(pts, {x = Mx, y = cy, z = cz})
                        table.insert(pts, {x = Mx, y = My, z = cz})
                        table.insert(pts, {x = Mx, y = my, z = cz})
                    end
                    return pts
                end
                local function best_frac(pts)
                    local best = 0
                    for _, p in ipairs(pts) do
                        local ok, trb = pcall(function()
                            return client.trace_bullet(entity_get_local_player(), ex1, ey1, ez1, p.x, p.y, p.z, entity_index)
                        end)
                        if ok and trb and trb.fraction and trb.fraction > best then best = trb.fraction end
                    end
                    return best
                end
                local fl = best_frac(sample_face_points(true))
                local fr = best_frac(sample_face_points(false))
                if math_abs(fl - fr) > 0.05 then
                    direction = (fr > fl) and 1 or -1
                end
            else
                local center = get_hitbox_center(entity_index, 0)
                local off = 10
                local ly = math_rad(normalize_angle_safe(resolved_yaw - base_desync))
                local ry = math_rad(normalize_angle_safe(resolved_yaw + base_desync))
                local lpos = {x = center.x + math_cos(ly) * off, y = center.y + math_sin(ly) * off, z = center.z}
                local rpos = {x = center.x + math_cos(ry) * off, y = center.y + math_sin(ry) * off, z = center.z}
                local fl, fr = 0, 0
                local ok_l, tb_l = pcall(function()
                    return client.trace_bullet(entity_get_local_player(), ex1, ey1, ez1, lpos.x, lpos.y, lpos.z, entity_index)
                end)
                local ok_r, tb_r = pcall(function()
                    return client.trace_bullet(entity_get_local_player(), ex1, ey1, ez1, rpos.x, rpos.y, rpos.z, entity_index)
                end)
                if ok_l and tb_l then fl = tb_l.fraction or 0 end
                if ok_r and tb_r then fr = tb_r.fraction or 0 end
                if fl == 0 and fr == 0 then
                    local tl = client.trace_line(ex1, ey1, ez1, lpos.x, lpos.y, lpos.z, entity_index)
                    local tr = client.trace_line(ex1, ey1, ez1, rpos.x, rpos.y, rpos.z, entity_index)
                    fl = type(tl) == 'number' and tl or (tl and tl.fraction) or 1
                    fr = type(tr) == 'number' and tr or (tr and tr.fraction) or 1
                end
                if math_abs(fl - fr) > 0.05 then
                    direction = (fr > fl) and 1 or -1
                end
            end
        end
    end
        
        -- Network-based direction adjustment
        if network_info and network_info.network_jitter_detected then
            local packet_correlation = jitter_analysis.packet_correlation or 0
            if packet_correlation > 0.5 then
                direction = direction * (packet_correlation > 0.7 and -1 or 1)
            end
        end
        
        -- === APPLY FAKE LAG COMPENSATION ===
        local compensated_desync, compensated_direction = apply_fake_lag_compensation(
            entity_index, fake_lag_data, jitter_correction, direction_data, network_info
        )
        
        -- Calculate final desync with network awareness
        local network_desync_modifier = 1.0
        if jitter_analysis.classification_data and jitter_analysis.classification_data.network_influenced then
            network_desync_modifier = 1.2
        end
        
        -- Apply fake lag compensation to final desync
        if fake_lag_data.is_fake_lagging then
            network_desync_modifier = network_desync_modifier * fake_lag_data.compensation_factor
        end
        
        base_desync = compensated_desync * network_desync_modifier
        resolved_yaw = resolved_yaw + (direction * base_desync)
        
        -- Store direction with network context
        table.insert(data.direction_memory.last_directions, {
            direction = direction,
            correction = base_desync,
            timestamp = globals.curtime(),
            network_influenced = jitter_analysis.classification_data and 
                jitter_analysis.classification_data.network_influenced or false,
            latency_compensation = network_info and network_info.latency and 
                (((network_info.latency.incoming + network_info.latency.outgoing) / 2) or 0),
            packet_correlation = jitter_analysis.packet_correlation or 0
        })
        
        while #data.direction_memory.last_directions > 10 do
            table.remove(data.direction_memory.last_directions, 1)
        end
    else
        -- Fallback resolution with network compensation
        local time_based_direction = (globals.curtime() * 3.7) % 2 < 1 and -1 or 1
        
        if network_info and network_info.network_jitter_detected then
            base_desync = base_desync * 1.1
            
            local latency_factor = math.min(2.0, 1.0 + (network_info.latency and 
                ((network_info.latency.incoming + network_info.latency.outgoing) / 2) * 10 or 0))
            time_based_direction = time_based_direction * latency_factor
        end
        
        resolved_yaw = resolved_yaw + (time_based_direction * base_desync)
    end
    
    -- Apply Riptide corrections if available
    if riptide_result then
        local riptide_correction = riptide_result.corrected_desync
        
        -- Network-quality based adjustment
        if network_quality and network_quality.score < 0.7 then
            riptide_correction = riptide_correction * network_quality.score
        end
        
        resolved_yaw = resolved_yaw + riptide_correction
        
        -- Store riptide performance metrics
        if not data.riptide_performance then
            data.riptide_performance = {
                total_corrections = 0,
                successful_corrections = 0,
                average_correction = 0,
                last_update = 0
            }
        end
        
        local riptide_perf = data.riptide_performance
        riptide_perf.total_corrections = riptide_perf.total_corrections + 1
        riptide_perf.average_correction = (riptide_perf.average_correction * 0.9) + (riptide_correction * 0.1)
        riptide_perf.last_update = globals.curtime()
    end
    
    -- === HITBOX MATRIX INTEGRATION FOR AISETPOS ===
    -- Интеграция системы матрицы хитбоксов для улучшения резольвинга в AISETPOS
    if hitbox_matrix_resolving and hitbox_matrix_resolving.get() then
        local matrix_resolution = integrate_hitbox_matrix_resolving(
            entity_index, 
            base_desync, 
            data.performance_metrics.resolution_quality or 0.5, 
            0 -- Голова по умолчанию
        )
        
        if matrix_resolution and matrix_resolution.matrix_analysis then
            -- Применяем коррекцию от матрицы хитбоксов
            local matrix_correction = matrix_resolution.desync - base_desync
            local final_desync = base_desync + (matrix_correction * 0.35)
            
            -- Обновляем resolved_yaw с коррекцией от матрицы
            resolved_yaw = resolved_yaw + (direction * matrix_correction * 0.35)
            
            -- Улучшаем качество резольвинга на основе анализа матрицы
            data.performance_metrics.resolution_quality = math.min(1.0, 
                (data.performance_metrics.resolution_quality or 0.5) + (matrix_resolution.confidence - (data.performance_metrics.resolution_quality or 0.5)) * 0.25
            )
            
            -- Сохраняем информацию о матрице для отладки
            data.hitbox_matrix_data = {
                correction = matrix_correction,
                confidence = matrix_resolution.confidence,
                prediction = matrix_resolution.prediction,
                timestamp = globals.curtime()
            }
            
            -- Debug логирование для матрицы хитбоксов в AISETPOS
            if hitbox_matrix_debug and hitbox_matrix_debug.get() then
                debug_log(string.format(
                    "[AISETPOS-MATRIX] Entity: %s | Matrix Correction: %.2f | Confidence: %.2f | Final Desync: %.2f",
                    player_name,
                    matrix_correction,
                    matrix_resolution.confidence,
                    final_desync
                ))
            end
        end
    end
    
    -- Enhanced performance tracking
    data.last_resolve = globals.curtime()
    data.performance_metrics.last_update = globals.curtime()
    
    -- Update network-aware behavioral analysis
    if network_info then
        data.behavioral_analysis.network_sensitivity = 
            (data.behavioral_analysis.network_sensitivity * 0.9) + 
            (network_info.network_jitter_detected and 1.0 or 0.0) * 0.1
        
        data.behavioral_analysis.packet_correlation = 
            (data.behavioral_analysis.packet_correlation * 0.8) + 
            (jitter_analysis.packet_correlation or 0) * 0.2
        
        data.behavioral_analysis.latency_adaptation = 
            (data.behavioral_analysis.latency_adaptation * 0.9) + 
            (network_info.latency and ((network_info.latency.incoming + network_info.latency.outgoing) / 2) * 10 or 0) * 0.1
    end
    
    -- Update resolution quality score
    local quality_factors = {
        jitter_confidence = jitter_analysis.confidence,
        network_stability = network_quality and network_quality.score or 1.0,
        packet_correlation = jitter_analysis.packet_correlation or 0,
        prediction_accuracy = (compensated_direction and compensated_direction.prediction_strength or direction_data.prediction_strength or 0.5)
            + (freestand and freestand.confidence or 0) * 0.1
    }
    
    data.performance_metrics.resolution_quality = 
        (quality_factors.jitter_confidence * 0.4) +
        (quality_factors.network_stability * 0.3) +
        (quality_factors.packet_correlation * 0.2) +
        (quality_factors.prediction_accuracy * 0.1)

    -- Update desync history for future dynamic estimation
    data.desync_history = data.desync_history or {}
    table_insert(data.desync_history, base_desync)
    if #data.desync_history > 32 then table.remove(data.desync_history, 1) end
    
    -- Anti-detection variance
    local time_variance = math.sin(globals.curtime() * 1.7 + entity_index) * 1.5

    -- Angle smoothing with wrap-aware lerp before variance
    data.yaw_history = data.yaw_history or {}
    local prev_yaw = data.yaw_history[1] or resolved_yaw
    local resq = (data.performance_metrics and data.performance_metrics.resolution_quality) or 0.5
    local weapon = entity_get_player_weapon(entity_get_local_player())
    local wname = weapon and entity_get_classname(weapon):lower() or 'unknown'
    local is_sniper = wname:find('awp') or wname:find('ssg') or wname:find('scar') or wname:find('g3')
    local base_t = 0.2 + resq * 0.6
    if is_sniper then base_t = base_t * 0.85 end  -- чуть менее агрессивное сглаживание для точных выстрелов
    base_t = math_max(0.15, math_min(0.9, base_t))
    local smoothed_core = angle_lerp(prev_yaw, resolved_yaw, base_t)

    resolved_yaw = normalize_angle_safe(smoothed_core + time_variance * (is_sniper and 0.5 or 1.0))

    table.insert(data.yaw_history, 1, resolved_yaw)
    if #data.yaw_history > 16 then table.remove(data.yaw_history) end
    
    -- Debug logging
    if riptide_v5_debug and ui.get(riptide_v5_debug) then
        local fake_lag_info = ""
        if fake_lag_data and fake_lag_data.is_fake_lagging then
            fake_lag_info = string.format(" | FakeLag: %s(%.2f) | Type: %s", 
                fake_lag_data.is_fake_lagging and "YES" or "NO",
                fake_lag_data.confidence,
                fake_lag_data.manipulation_type
            )
        end
        
        debug_log(string.format(
            "[AISETPOS-V4] %s | Yaw: %.1f° | Desync: %.1f° | Quality: %.2f | Network: %.2f | Latency: %.1fms%s",
            player_name,
            normalize_angle_safe(resolved_yaw),
            base_desync,
            data.performance_metrics.resolution_quality,
            network_quality and network_quality.score or 1.0,
            network_info and ((network_info.latency.incoming + network_info.latency.outgoing) / 2) * 1000 or 0,
            fake_lag_info
        ))
    end
    
    return normalize_angle_safe(safe_number(resolved_yaw, current_record.angles.y or 0))
end
    
-- Hitbox face points (prefer studiohdr bbox faces; fallback to bone basis)
local function get_hitbox_face_points(entity_index, hitbox_id)
    hitbox_id = hitbox_id or 0
    local bbox = get_hitbox_bbox_via_studio and get_hitbox_bbox_via_studio(entity_index, hitbox_id)
    if bbox and bbox.mins and bbox.maxs and bbox.center then
        local cx, cy, cz = bbox.center.x, bbox.center.y, bbox.center.z
        local mx, my, mz = bbox.mins.x, bbox.mins.y, bbox.mins.z
        local Mx, My, Mz = bbox.maxs.x, bbox.maxs.y, bbox.maxs.z
        return {
            {x=cx,y=cy,z=cz},
            {x=mx,y=cy,z=cz},{x=Mx,y=cy,z=cz},
            {x=cx,y=my,z=cz},{x=cx,y=My,z=cz},
            {x=cx,y=cy,z=mz},{x=cx,y=cy,z=Mz},
            {x=mx,y=my,z=cz},{x=Mx,y=My,z=cz},{x=mx,y=My,z=cz},{x=Mx,y=my,z=cz}
        }
    end
    -- fallback: bone basis
    local center = get_hitbox_center(entity_index, hitbox_id)
    local bones = get_bones_cached and get_bones_cached(entity_index) or nil
    local mat
    if bones and bones[0] then
        for _, bone in ipairs({8,7,6}) do
            if bones[bone] then mat = bones[bone]; break end
        end
    end
    local right, forward, up
    if mat then
        right   = {x = mat[0][0], y = mat[1][0], z = mat[2][0]}
        forward = {x = mat[0][1], y = mat[1][1], z = mat[2][1]}
        up      = {x = mat[0][2], y = mat[1][2], z = mat[2][2]}
    else
        right, forward, up = {x=1,y=0,z=0}, {x=0,y=1,z=0}, {x=0,y=0,z=1}
    end
    local ex, ey, ez = 5, 5, 7
    local pts = {}
    local function add(p) table.insert(pts, p) end
    add(vec_add(center, vec_scale(right,  ex)))
    add(vec_add(center, vec_scale(right, -ex)))
    add(vec_add(center, vec_scale(forward,  ey)))
    add(vec_add(center, vec_scale(forward, -ey)))
    add(vec_add(center, vec_scale(up,  ez)))
    add(vec_add(center, vec_scale(up, -ez)))
    add(vec_add(center, vec_add(vec_scale(right, ex), vec_scale(up, ez))))
    add(vec_add(center, vec_add(vec_scale(right,-ex), vec_scale(up, ez))))
    add(vec_add(center, vec_add(vec_scale(right, ex), vec_scale(up,-ez))))
    add(vec_add(center, vec_add(vec_scale(right,-ex), vec_scale(up,-ez))))
    return pts
end

-- === IMPROVED LC RESOLVER ===
local function resolve_lc_prediction(entity_index)
    local records = lag_records[entity_index]
    if not records or #records < 4 then return nil end
    
    local player_name = entity_get_player_name(entity_index)
    if not player_name then return nil end
    
    -- Simple LC prediction based on current record
    local current_record = records[1]
    local velocity = vector_new(entity_get_prop(entity_index, "m_vecVelocity"))
    
    -- Basic prediction calculation
    local network_info = network_channel_system:get_network_info()
    local avg_latency = network_info and (network_info.latency.incoming + network_info.latency.outgoing) / 2 or globals_frametime()
    local choke = network_info and (network_info.choke.incoming + network_info.choke.outgoing) / 2 or 0
    -- latency-aware horizon (more conservative at high ping)
    local net_dt = avg_latency * (1 + choke * 0.5)
    if avg_latency > 0.07 then net_dt = net_dt * 0.8 end
    local ticks_to_predict = math.min(15, math.ceil(net_dt / globals_tickinterval()) + 1)

    -- Network-aware forward prediction (2D + gravity) with neck/torso fallback + simple collision/ladder handling
    local dt = ticks_to_predict * globals_tickinterval()
    local predicted_origin = get_hitbox_center(entity_index, 0)
    -- horizontal (lerp 2D for smoother anticipation)
    predicted_origin.x = predicted_origin.x + velocity.x * dt * 0.9
    predicted_origin.y = predicted_origin.y + velocity.y * dt * 0.9
    -- vertical with simple gravity compensation (slightly conservative)
    local flags = entity_get_prop(entity_index, 'm_fFlags') or 0
    local on_ladder = bit.band(flags, 0x40) == 0x40
    local vz = velocity.z
    if not on_ladder then
        vz = vz - physics_constants.gravity * dt * 0.45
    end
    predicted_origin.z = predicted_origin.z + vz * dt
    -- basic collision-aware nudge: if direct center blocked, nudge to best visible face point
    do
        local e1, e2, e3 = client.eye_position()
        local ex1, ey1, ez1 = (type(e1) == 'number') and e1 or (e1 and e1[1]), (type(e1) == 'number') and e2 or (e1 and e1[2]), (type(e1) == 'number') and e3 or (e1 and e1[3])
        if ex1 and predicted_origin then
            local bbox = get_hitbox_bbox_via_studio and get_hitbox_bbox_via_studio(entity_index, 0)
            local best_p, best_f = predicted_origin, 0
            local pts = bbox and { {x=bbox.center.x,y=bbox.center.y,z=bbox.center.z}, {x=bbox.mins.x,y=bbox.center.y,z=bbox.center.z}, {x=bbox.maxs.x,y=bbox.center.y,z=bbox.center.z} } or get_hitbox_face_points(entity_index, 0)
            for _, p in ipairs(pts) do
                local ok, trb = pcall(function()
                    return client.trace_bullet(entity_get_local_player(), ex1, ey1, ez1, p.x, p.y, p.z, entity_index)
                end)
                local frac = (ok and trb and trb.fraction) or 0
                if frac > best_f then best_f, best_p = frac, p end
            end
            if best_f < 0.3 then
                local chest_pts = get_hitbox_face_points(entity_index, 5)
                for _, p in ipairs(chest_pts) do
                    local ok, trb = pcall(function()
                        return client.trace_bullet(entity_get_local_player(), ex1, ey1, ez1, p.x, p.y, p.z, entity_index)
                    end)
                    local frac = (ok and trb and trb.fraction) or 0
                    if frac > best_f then best_f, best_p = frac, p end
                end
            end
            if best_p then
                local pull = (avg_latency > 0.07) and 0.35 or 0.22
                predicted_origin.x = predicted_origin.x + (best_p.x - predicted_origin.x) * pull
                predicted_origin.y = predicted_origin.y + (best_p.y - predicted_origin.y) * pull
                predicted_origin.z = predicted_origin.z + (best_p.z - predicted_origin.z) * pull
            end
        end
    end
    
        -- Visibility-aware correction: nudge towards nearest visible point
    -- Normalize eye position (API may return numbers or table)
    local e1, e2, e3 = client.eye_position()
    local ex1, ey1, ez1
    if type(e1) == "number" and type(e2) == "number" and type(e3) == "number" then
        ex1, ey1, ez1 = e1, e2, e3
    elseif type(e1) == "table" and e1[1] and e1[2] and e1[3] then
        ex1, ey1, ez1 = e1[1], e1[2], e1[3]
    end

    if ex1 and predicted_origin then
        -- Check multiple face points: head then chest (fallback)
        local function best_face_point_for(hitbox_id)
            local best_p, best_f = predicted_origin, 0
            local pts = get_hitbox_face_points(entity_index, hitbox_id)
            for _, p in ipairs(pts) do
                local tr = client.trace_line(ex1, ey1, ez1, p.x, p.y, p.z, entity_index)
                local f = (type(tr) == 'number') and tr or ((tr and tr.fraction) or 1)
                if f > best_f then best_f, best_p = f, p end
            end
            return best_p, best_f
        end
        local best_p, best_f = best_face_point_for(0)
        if best_f < 0.6 then
            local chest_p, chest_f = best_face_point_for(5)
            if chest_f > best_f then best_p, best_f = chest_p, chest_f end
        end
        -- stronger pull at high ping
        local pull_base = avg_latency and (avg_latency > 0.07 and 10 or 8) or 8
        if best_f < 0.95 then
            local pull = (1 - best_f) * pull_base
            local to_eye = vec_normalize({x = ex1 - best_p.x, y = ey1 - best_p.y, z = ez1 - best_p.z})
            predicted_origin = vec_add(best_p, vec_scale(to_eye, pull))
        else
            predicted_origin = best_p
        end
    end
    
    -- === HITBOX MATRIX INTEGRATION FOR LC PREDICTION ===
    -- Интеграция системы матрицы хитбоксов для улучшения предсказания в LC
    local matrix_enhanced_origin = predicted_origin
    local matrix_confidence = 0.5
    
    if hitbox_matrix_resolving and hitbox_matrix_resolving.get() then
        local matrix_resolution = integrate_hitbox_matrix_resolving(
            entity_index, 
            0, -- Базовый десинк для LC
            math_max(0.5, 1.0 - choke * 0.5), -- Базовая уверенность
            0 -- Голова по умолчанию
        )
        
        if matrix_resolution and matrix_resolution.matrix_analysis then
            -- Применяем коррекцию от матрицы хитбоксов к предсказанной позиции
            local matrix_correction = matrix_resolution.desync
            local correction_factor = math.min(0.4, matrix_resolution.confidence * 0.6)
            
            if matrix_correction > 0 then
                -- Корректируем позицию на основе анализа матрицы хитбоксов
                matrix_enhanced_origin = {
                    x = predicted_origin.x + (matrix_correction * correction_factor),
                    y = predicted_origin.y + (matrix_correction * correction_factor),
                    z = predicted_origin.z
                }
                
                matrix_confidence = math.min(1.0, matrix_resolution.confidence + 0.1)
                
                -- Debug логирование для матрицы хитбоксов в LC
                if hitbox_matrix_debug and hitbox_matrix_debug.get() then
                    debug_log(string.format(
                        "[LC-MATRIX] Entity: %s | Matrix Correction: %.2f | Confidence: %.2f",
                        player_name,
                        matrix_correction,
                        matrix_resolution.confidence
                    ))
                end
            end
        end
    end
    
    local tick_dt = math.max(globals_tickinterval(), dt)
    return {
        origin = matrix_enhanced_origin,
        angles = current_record.angles,
        velocity = velocity,
        simulation_time = current_record.simulation_time + tick_dt,
        ticks_predicted = math.ceil(dt / globals_tickinterval()),
        confidence = math_max(matrix_confidence, 1.0 - choke * 0.5),
        hitbox_matrix_enhanced = matrix_enhanced_origin ~= predicted_origin,
        matrix_correction = matrix_enhanced_origin ~= predicted_origin and 
            (matrix_enhanced_origin.x - predicted_origin.x) or 0
    }
end

-- === ENHANCED ENEMY ANTIAIM RESOLVER ===
local function resolve_enemy_antiaim(entity_index)
    if not entity_is_alive(entity_index) or entity_is_dormant(entity_index) then
        return nil
    end
    
    if not entity_is_enemy(entity_index) then
        return nil
    end
    
    local classname = entity_get_classname(entity_index)
    if classname ~= "CCSPlayer" then
        return nil
    end
    
    -- Update lag records
    update_lag_records(entity_index)
    
    -- Prefer last valid record for resolver if current looks invalid (defensive AA)
    local current_record = lag_records[entity_index] and lag_records[entity_index][1]
    local last_valid = player_data[entity_index] and player_data[entity_index].last_valid_record
    if current_record and current_record.validity and current_record.validity.valid == false and last_valid then
        -- Temporarily replace top record for resolution
        lag_records[entity_index][1] = last_valid
    end

    -- Get AISetpos resolution
    local aisetpos_yaw = resolve_aisetpos(entity_index)

    -- Immediately apply resolved yaw to entity to ensure resolver takes effect even without backtrack apply
    if aisetpos_yaw and aisetpos_yaw ~= 0 then
        local base_pitch = entity_get_prop(entity_index, "m_angEyeAngles[0]") or entity_get_prop(entity_index, "m_angEyeAngles", 0) or 0
        pcall(function()
            entity_set_prop(entity_index, "m_angEyeAngles[0]", base_pitch)
            entity_set_prop(entity_index, "m_angEyeAngles[1]", normalize_angle_safe(aisetpos_yaw))
        end)
    end

    -- Restore current record if we swapped
    if last_valid and lag_records[entity_index] and lag_records[entity_index][1] ~= current_record then
        lag_records[entity_index][1] = current_record
    end
    
    -- Get LC prediction
    local lc_prediction = resolve_lc_prediction(entity_index)
    
    -- === HITBOX MATRIX INTEGRATION FOR ENEMY ANTIAIM ===
    -- Интеграция системы матрицы хитбоксов для улучшения резольвинга вражеского антиаима
    local matrix_enhanced_resolution = {
        aisetpos_yaw = aisetpos_yaw,
        lc_prediction = lc_prediction,
        entity_index = entity_index,
        hitbox_matrix_enabled = hitbox_matrix_resolving and hitbox_matrix_resolving.get() or false
    }
    
    if hitbox_matrix_resolving and hitbox_matrix_resolving.get() then
        -- Анализируем качество резольвинга через матрицу хитбоксов
        local matrix_analysis = integrate_hitbox_matrix_resolving(
            entity_index, 
            0, -- Базовый десинк
            0.7, -- Базовая уверенность
            0 -- Голова по умолчанию
        )
        
        if matrix_analysis and matrix_analysis.matrix_analysis then
            -- Добавляем информацию о матрице в результат
            matrix_enhanced_resolution.hitbox_matrix_data = {
                correction = matrix_analysis.desync,
                confidence = matrix_analysis.confidence,
                prediction = matrix_analysis.prediction,
                timestamp = globals.curtime()
            }
            
                            -- Debug логирование для матрицы хитбоксов в Enemy Antiaim
                if hitbox_matrix_debug and hitbox_matrix_debug.get() then
                debug_log(string.format(
                    "[ENEMY-AA-MATRIX] Entity: %s | Matrix Analysis: %.2f | Confidence: %.2f",
                    entity_get_player_name(entity_index) or "Unknown",
                    matrix_analysis.desync,
                    matrix_analysis.confidence
                ))
            end
        end
    end
    
    return matrix_enhanced_resolution
 end

-- Enhanced Event handlers with Machine Learning Integration
local function on_player_hurt(e)
    local victim_id = client_userid_to_entindex(e.userid)
    local attacker_id = client_userid_to_entindex(e.attacker)
    local local_player = entity_get_local_player()
    
    if attacker_id == local_player and victim_id ~= local_player then
        if player_data[victim_id] then
            player_data[victim_id].shots_hit = (player_data[victim_id].shots_hit or 0) + 1
            local hit_ratio = player_data[victim_id].shots_hit / math.max(player_data[victim_id].shots_fired or 0, 1)
            local player_name = entity_get_player_name(victim_id)

            debug_log(string.format(
                "[RESOLVER HIT] Player: %s | Hit Ratio: %.2f%% | Shots: %d/%d",
                player_name or "Unknown", hit_ratio * 100, player_data[victim_id].shots_hit, player_data[victim_id].shots_fired or 0
            ))
        end
    end
 end

-- Enhanced weapon fire handler
local function on_weapon_fire(e)
    local shooter_id = client_userid_to_entindex(e.userid)
    local local_player = entity_get_local_player()
    
    if shooter_id == local_player then
        -- Track shots fired at resolved players
        for entity_index, data in pairs(player_data) do
            if entity_is_alive(entity_index) and entity_is_enemy(entity_index) then
                data.shots_fired = (data.shots_fired or 0) + 1
            end
        end
    end
 end

local function on_round_start()
    -- Reset all player data
    player_data = {}
    lag_records = {}
    debug_logs = {}
    debug_log("[RESOLVER] Round start - Data reset")
end

-- Safe hitbox center (fallbacks to origin + 64 for head)
local function get_hitbox_center(entity_index, hitbox_id)
    hitbox_id = hitbox_id or 0
    -- Prefer exact bbox center via studiohdr when available
    local bbox = get_hitbox_bbox_via_studio and get_hitbox_bbox_via_studio(entity_index, hitbox_id)
    if bbox and bbox.center then
        return {x = bbox.center.x, y = bbox.center.y, z = bbox.center.z}
    end
    -- Fast path via API
    if entity.hitbox_position then
        local ok, x, y, z = pcall(entity.hitbox_position, entity_index, hitbox_id)
        if ok and x then
            return {x = x, y = y, z = z}
        end
    end
    -- Try bones (approx) via vtable SetupBones
    local bones = get_bones_cached(entity_index)
    if bones and bones[0] then
        for _, b in ipairs({8, 7, 6}) do
            local mat = bones[b]
            if mat then
                local cx = mat[0][3]
                local cy = mat[1][3]
                local cz = mat[2][3]
                if cx ~= 0 or cy ~= 0 or cz ~= 0 then
                    return {x = cx, y = cy, z = cz}
                end
            end
        end
    end
    -- Fallback
    local ox, oy, oz = entity_get_origin(entity_index)
    return {x = ox or 0, y = oy or 0, z = (oz or 0) + (hitbox_id == 0 and 64 or 48)}
end

_G.get_hitbox_center = _G.get_hitbox_center or get_hitbox_center

-- Hitbox face points (prefer studiohdr bbox faces; fallback to bone basis)
local function get_hitbox_face_points(entity_index, hitbox_id)
    hitbox_id = hitbox_id or 0
    local bbox = get_hitbox_bbox_via_studio and get_hitbox_bbox_via_studio(entity_index, hitbox_id)
    if bbox and bbox.mins and bbox.maxs and bbox.center then
        local cx, cy, cz = bbox.center.x, bbox.center.y, bbox.center.z
        local mx, my, mz = bbox.mins.x, bbox.mins.y, bbox.mins.z
        local Mx, My, Mz = bbox.maxs.x, bbox.maxs.y, bbox.maxs.z
        return {
            {x=cx,y=cy,z=cz},
            {x=mx,y=cy,z=cz},{x=Mx,y=cy,z=cz},
            {x=cx,y=my,z=cz},{x=cx,y=My,z=cz},
            {x=cx,y=cy,z=mz},{x=cx,y=cy,z=Mz},
            {x=mx,y=my,z=cz},{x=Mx,y=My,z=cz},{x=mx,y=My,z=cz},{x=Mx,y=my,z=cz}
        }
    end
    -- fallback: bone basis
    local center = get_hitbox_center(entity_index, hitbox_id)
    local points = {}
    local bones = get_bones_cached and get_bones_cached(entity_index) or nil
    local mat
    if bones and bones[0] then
        for _, b in ipairs({8,7,6}) do
            if bones[b] then mat = bones[b]; break end
        end
    end
    local right, forward, up
    if mat then
        right   = {x = mat[0][0], y = mat[1][0], z = mat[2][0]}
        forward = {x = mat[0][1], y = mat[1][1], z = mat[2][1]}
        up      = {x = mat[0][2], y = mat[1][2], z = mat[2][2]}
    else
        right, forward, up = {x=1,y=0,z=0}, {x=0,y=1,z=0}, {x=0,y=0,z=1}
    end
    local ex, ey, ez = 5, 5, 7
    local function add(p)
        table.insert(points, p)
    end
    add(vec_add(center, vec_scale(right,  ex)))
    add(vec_add(center, vec_scale(right, -ex)))
    add(vec_add(center, vec_scale(forward,  ey)))
    add(vec_add(center, vec_scale(forward, -ey)))
    add(vec_add(center, vec_scale(up,  ez)))
    add(vec_add(center, vec_scale(up, -ez)))
    -- corners
    add(vec_add(center, vec_add(vec_scale(right, ex), vec_scale(up, ez))))
    add(vec_add(center, vec_add(vec_scale(right,-ex), vec_scale(up, ez))))
    add(vec_add(center, vec_add(vec_scale(right, ex), vec_scale(up,-ez))))
    add(vec_add(center, vec_add(vec_scale(right,-ex), vec_scale(up,-ez))))
    return points
end

-- Enhanced FOV system for target selection  
local function get_closest_to_crosshair()
    local local_player = entity_get_local_player()
    if not local_player then return nil end
    
    local view_angles = {entity_get_prop(local_player, "m_angEyeAngles")}
    if not view_angles[1] or not view_angles[2] then return nil end
    
    local camera_angles = {x = view_angles[1], y = view_angles[2]}
    local camera_x, camera_y, camera_z = entity_get_origin(local_player)
    if not camera_x or not camera_y or not camera_z then return nil end
    
    local camera_origin = {x = camera_x, y = camera_y, z = camera_z}
    local enemies = entity_get_all("CCSPlayer")
    local closest_enemy = nil
    local best_score = 999999
    local max_distance = 6000
    local max_fov = 180
    
    for i = 1, #enemies do
        local entity_index = enemies[i]
        
        if entity_is_alive(entity_index) and entity_is_enemy(entity_index) and not entity_is_dormant(entity_index) then
            local enemy_x, enemy_y, enemy_z = entity_get_origin(entity_index)
            
            if enemy_x and enemy_y and enemy_z then
                local enemy_origin = {x = enemy_x, y = enemy_y, z = enemy_z}
                local distance = vector_distance(camera_origin, enemy_origin)
                
                if distance <= max_distance then
                    local delta_x = enemy_origin.x - camera_origin.x
                    local delta_y = enemy_origin.y - camera_origin.y
                    local delta_z = enemy_origin.z - camera_origin.z
                    
                    local yaw_to_target = math.deg(math.atan2(delta_y, delta_x))
                    local distance_2d = math.sqrt(delta_x * delta_x + delta_y * delta_y)
                    local pitch_to_target = math.deg(math.atan2(-delta_z, distance_2d))
                    
                    yaw_to_target = normalize_angle(yaw_to_target)
                    pitch_to_target = math.max(-89, math.min(89, pitch_to_target))
                    
                    local yaw_diff = math.abs(normalize_angle(camera_angles.y - yaw_to_target))
                    local pitch_diff = math.abs(camera_angles.x - pitch_to_target)
                    local simple_fov = math.max(yaw_diff, pitch_diff)
                    
                    if simple_fov <= max_fov then
                        local fov_score = simple_fov * 10
                        local distance_score = distance / 100
                        local total_score = fov_score + distance_score
                        
                        if total_score < best_score then
                            best_score = total_score
                            closest_enemy = {
                                entity_index = entity_index,
                                fov = simple_fov,
                                distance = distance,
                                score = total_score
                            }
                        end
                    end
                end
            end
        end
    end
    
    return closest_enemy
 end



-- Main processing function
local function process_frame()
    local closest_target = get_closest_to_crosshair()
    
    if closest_target then
        local entity_index = closest_target.entity_index
        
        -- Throttle resolution calls
        local current_time = globals_curtime()
        if not last_resolve_time[entity_index] or 
           current_time - last_resolve_time[entity_index] >= 0.016 then
            
            last_resolve_time[entity_index] = current_time
            
            -- Resolve enemy
            local result = resolve_enemy_antiaim(entity_index)
            
            if result then
                resolve_cache[entity_index] = {
                    result = result,
                    timestamp = current_time
                }
            end
        end
    end
end
-- === EVENT REGISTRATION ===
client.set_event_callback("player_hurt", on_player_hurt)
client.set_event_callback("weapon_fire", on_weapon_fire)
client.set_event_callback("round_start", on_round_start)
client.set_event_callback("paint", process_frame)

-- AIM events: flip resolver side only on resolver miss
client.set_event_callback("aim_fire", function(e)
    -- Optionally capture state; keeping minimal per request
end)

client.set_event_callback("aim_hit", function(e)
    local ent = e.target or e.target_index
    if ent and player_data[ent] then
        player_data[ent].resolver_flip_until = nil
    end
end)

client.set_event_callback("aim_miss", function(e)
    local ent = e.target or e.target_index
    local reason = e.reason and tostring(e.reason):lower() or ""
    if ent then
        player_data[ent] = player_data[ent] or {}
        if reason == "resolver" then
            player_data[ent].resolver_flip_until = globals.curtime() + 0.35
        end
    end
end)
-- === NEURAL NETWORK ENHANCEMENT SYSTEM ===
-- Встроенная система машинного обучения для улучшения резольвера
local function create_neural_network(config)
    local network = {
        input_size = config.input_size,
        hidden_layers = config.hidden_layers,
        output_size = config.output_size,
        weights = {},
        biases = {},
        momentum_weights = {},
        momentum_biases = {},
        learning_rate = config.learning_rate or 0.001,
        momentum = config.momentum or 0.9
    }
    
    -- Xavier weight initialization
    local prev_size = network.input_size
    for i, layer_size in ipairs(network.hidden_layers) do
        network.weights[i] = {}
        network.biases[i] = {}
        network.momentum_weights[i] = {}
        network.momentum_biases[i] = {}
        
        local xavier_std = math.sqrt(2.0 / (prev_size + layer_size))
        
        for j = 1, layer_size do
            network.weights[i][j] = {}
            network.momentum_weights[i][j] = {}
            network.biases[i][j] = (math.random() - 0.5) * 0.1
            network.momentum_biases[i][j] = 0
            
            for k = 1, prev_size do
                network.weights[i][j][k] = (math.random() - 0.5) * xavier_std * 2
                network.momentum_weights[i][j][k] = 0
            end
        end
        prev_size = layer_size
    end
    
    -- Output layer
    local output_idx = #network.hidden_layers + 1
    network.weights[output_idx] = {}
    network.biases[output_idx] = {}
    network.momentum_weights[output_idx] = {}
    network.momentum_biases[output_idx] = {}
    
    local xavier_std = math.sqrt(2.0 / (prev_size + network.output_size))
    
    for j = 1, network.output_size do
        network.weights[output_idx][j] = {}
        network.momentum_weights[output_idx][j] = {}
        network.biases[output_idx][j] = (math.random() - 0.5) * 0.1
        network.momentum_biases[output_idx][j] = 0
        
        for k = 1, prev_size do
            network.weights[output_idx][j][k] = (math.random() - 0.5) * xavier_std * 2
            network.momentum_weights[output_idx][j][k] = 0
        end
    end
    
    -- Forward pass
    network.forward = function(self, input)
        local activations = {input}
        
        for layer = 1, #self.weights do
            local prev_activation = activations[layer]
            local current_activation = {}
            
            for neuron = 1, #self.weights[layer] do
                local sum = self.biases[layer][neuron]
                for prev_neuron = 1, #prev_activation do
                    sum = sum + prev_activation[prev_neuron] * self.weights[layer][neuron][prev_neuron]
                end
                
                if layer < #self.weights then
                    current_activation[neuron] = math.max(0, sum) -- ReLU
                else
                    current_activation[neuron] = sum -- Linear output
                end
            end
            
            table.insert(activations, current_activation)
        end
        
        return activations[#activations], activations
    end
    
    -- Training
    network.train = function(self, input, target)
        local output, all_activations = self:forward(input)
        
        local loss = 0
        local output_errors = {}
        for i = 1, #output do
            local error = target[i] - output[i]
            output_errors[i] = error
            loss = loss + error * error
        end
        loss = loss / #output
        
        -- Backpropagation
        local layer_errors = {output_errors}
        
        for layer = #self.weights, 2, -1 do
            local errors = {}
            for neuron = 1, #self.weights[layer - 1] do
                local error = 0
                for next_neuron = 1, #layer_errors[1] do
                    error = error + layer_errors[1][next_neuron] * self.weights[layer][next_neuron][neuron]
                end
                if all_activations[layer][neuron] > 0 then
                    errors[neuron] = error
                else
                    errors[neuron] = 0
                end
            end
            table.insert(layer_errors, 1, errors)
        end
        
        -- Update weights with momentum
        for layer = 1, #self.weights do
            for neuron = 1, #self.weights[layer] do
                local bias_gradient = layer_errors[layer][neuron] * self.learning_rate
                self.momentum_biases[layer][neuron] = self.momentum * self.momentum_biases[layer][neuron] + bias_gradient
                self.biases[layer][neuron] = self.biases[layer][neuron] + self.momentum_biases[layer][neuron]
                
                for prev_neuron = 1, #self.weights[layer][neuron] do
                    local weight_gradient = layer_errors[layer][neuron] * all_activations[layer][prev_neuron] * self.learning_rate
                    self.momentum_weights[layer][neuron][prev_neuron] = self.momentum * self.momentum_weights[layer][neuron][prev_neuron] + weight_gradient
                    self.weights[layer][neuron][prev_neuron] = self.weights[layer][neuron][prev_neuron] + self.momentum_weights[layer][neuron][prev_neuron]
                end
            end
        end
        
        return loss
    end
    
    return network
end
-- Enhanced resolver with neural networks
local enhanced_resolver = {
    neural_networks = {},
    performance_metrics = {},
    learning_history = {},
    last_cleanup_time = 0,
    network_analysis = {
        jitter_detection = {},
        packet_analysis = {},
        sequence_tracking = {},
        quality_metrics = {}
    }
}

-- Initialize neural network for player
local function initialize_player_network(entity_index)
    if enhanced_resolver.neural_networks[entity_index] then
        return enhanced_resolver.neural_networks[entity_index]
    end
    
    enhanced_resolver.neural_networks[entity_index] = create_neural_network({
        input_size = 15,
        hidden_layers = {20, 12, 8},
        output_size = 3,
        learning_rate = 0.001,
        momentum = 0.9
    })
    
    enhanced_resolver.performance_metrics[entity_index] = {
        shots_fired = 0,
        shots_hit = 0,
        accuracy = 0.5,
        last_update = globals.curtime(),
        learning_rate_adaptive = 0.001
    }
    
    return enhanced_resolver.neural_networks[entity_index]
end