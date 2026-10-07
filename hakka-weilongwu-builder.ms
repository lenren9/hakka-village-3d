/*
 Hakka Weilongwu Basic Model Builder
 Target: 3ds Max 2022
 Units: designed for 1 system unit = 1 meter.

 The script creates a clean, editable base model with:
 - Three halls on the central axis (lower, middle and upper halls)
 - Symmetrical horizontal wings
 - A semicircular Huatai covered by dense cobblestones
 - One or two concentric semicircular Weilong rings
 - A semicircular Fengshui pond in front
 - Standard materials for grey-white brick, roof tiles, wood and water

 Run:
 1. Open 3ds Max 2022.
 2. Open Scripting > New Script.
 3. Paste this entire file into the MAXScript editor.
 4. Press Ctrl+E, or choose Tools > Evaluate All.

 The generated hierarchy uses Dummy nodes and is intentionally kept free of
 modifiers so it can be adjusted manually before exporting to GLB.
*/

global HAKKA_RING_COUNT = 2
global HAKKA_HUATAI_PEBBLES = 280

fn purgePreviousHakkaModel =
(
    local doomed = #()
    for obj in objects where matchPattern obj.name pattern:"HakkaWeilongwu_*" do append doomed obj
    for obj in doomed where isValidNode obj do delete obj
)

fn makeStandardMaterial matName diffuseColor specularAmount glossAmount opacityAmount =
(
    local mat = StandardMaterial name:matName diffuse:diffuseColor
    mat.specularLevel = specularAmount
    mat.glossiness = glossAmount
    mat.opacity = opacityAmount
    mat.twoSided = false
    mat
)

fn makeBox objName objWidth objLength objHeight objPosition parentNode mat =
(
    local obj = Box width:objWidth length:objLength height:objHeight pos:objPosition name:objName
    obj.material = mat
    obj.castShadows = true
    obj.receiveShadows = true
    if parentNode != undefined do obj.parent = parentNode
    obj
)

fn makeColumn objName radiusAmount columnHeight objPosition parentNode mat =
(
    local obj = Cylinder radius:radiusAmount height:columnHeight sides:12 pos:objPosition name:objName
    obj.material = mat
    obj.castShadows = true
    obj.receiveShadows = true
    if parentNode != undefined do obj.parent = parentNode
    obj
)

fn makeRoof objName roofWidth roofDepth roofRise basePosition parentNode mat includeRibs =
(
    local halfWidth = roofWidth * 0.5
    local halfDepth = roofDepth * 0.5
    local verts = #(
        [-halfWidth, -halfDepth, 0.0],
        [ halfWidth, -halfDepth, 0.0],
        [ halfWidth,  halfDepth, 0.0],
        [-halfWidth,  halfDepth, 0.0],
        [-halfWidth, 0.0, roofRise],
        [ halfWidth, 0.0, roofRise]
    )
    local faces = #(
        [1, 2, 6, 5],
        [4, 5, 6, 3],
        [1, 5, 4],
        [2, 3, 6],
        [1, 4, 3, 2]
    )

    local roofMesh = mesh vertices:verts faces:faces name:objName
    roofMesh.pos = basePosition
    roofMesh.material = mat
    roofMesh.castShadows = true
    roofMesh.receiveShadows = true
    if parentNode != undefined do roofMesh.parent = parentNode
    addModifier roofMesh (Normalmodifier())

    if includeRibs do
    (
        local ribCount = amax 6 (amin 22 (floor (roofWidth / 0.62)))
        local slopeLength = sqrt ((halfDepth * halfDepth) + (roofRise * roofRise))
        local slopeAngle = atan2 roofRise halfDepth
        for sideIndex = -1 to 1 by 2 do
        (
            for ribIndex = 1 to ribCount do
            (
                local localX = -halfWidth + ((ribIndex - 0.5) * roofWidth / ribCount)
                local localY = sideIndex * halfDepth * 0.5
                local rib = makeBox (objName + "_TileRib") 0.065 slopeLength 0.055 [localX, localY, roofRise * 0.5] parentNode mat
                rib.rotation.x = sideIndex * slopeAngle
                rib.pos = basePosition + [localX, localY, roofRise * 0.5]
            )
        )
    )
    roofMesh
)

fn makeDoorAndWindows prefix width length wallHeight baseZ parentNode matWood matDark =
(
    local frontY = (length * 0.5) + 0.12
    local doorWidth = amin 1.65 (width * 0.25)
    local doorHeight = amin 2.25 (wallHeight * 0.72)

    makeBox (prefix + "_DoorOpening") doorWidth 0.12 doorHeight [0.0, frontY, baseZ + (doorHeight * 0.5)] parentNode matDark
    makeBox (prefix + "_DoorLeft") 0.17 0.22 (doorHeight + 0.34) [-(doorWidth * 0.5 + 0.12), frontY + 0.04, baseZ + (doorHeight * 0.5)] parentNode matWood
    makeBox (prefix + "_DoorRight") 0.17 0.22 (doorHeight + 0.34) [(doorWidth * 0.5 + 0.12), frontY + 0.04, baseZ + (doorHeight * 0.5)] parentNode matWood
    makeBox (prefix + "_DoorLintel") (doorWidth + 0.7) 0.24 0.22 [0.0, frontY + 0.05, baseZ + doorHeight + 0.18] parentNode matWood

    for sideIndex = -1 to 1 by 2 do
    (
        local windowX = sideIndex * width * 0.31
        local windowZ = baseZ + wallHeight * 0.56
        makeBox (prefix + "_WindowOpening") 0.84 0.12 0.72 [windowX, frontY, windowZ] parentNode matDark
        makeBox (prefix + "_WindowFrameV") 0.075 0.11 0.72 [windowX, frontY + 0.055, windowZ] parentNode matWood
        makeBox (prefix + "_WindowFrameH") 0.84 0.11 0.075 [windowX, frontY + 0.055, windowZ] parentNode matWood
    )
)

fn makeGableBuilding prefix localPosition rotationZ width length wallHeight roofHeight parentNode matWall matRoof matWood matDark =
(
    local root = Dummy name:(prefix + "_ROOT") boxsize:[width, length, wallHeight + roofHeight]
    if parentNode != undefined do root.parent = parentNode

    local plinthHeight = 0.42
    makeBox (prefix + "_Plinth") (width + 0.48) (length + 0.48) plinthHeight [0.0, 0.0, plinthHeight * 0.5] root matWall
    makeBox (prefix + "_Wall") width length wallHeight [0.0, 0.0, plinthHeight + (wallHeight * 0.5)] root matWall

    local roofBaseZ = plinthHeight + wallHeight
    makeRoof (prefix + "_HardMountainRoof") (width + 0.92) (length + 0.96) roofHeight [0.0, 0.0, roofBaseZ] root matRoof true

    local ridge = Cylinder radius:0.105 height:(width + 0.65) sides:10 pos:[0.0, 0.0, roofBaseZ + roofHeight] name:(prefix + "_Ridge")
    ridge.rotation = eulerangles 0 90 0
    ridge.material = matRoof
    ridge.castShadows = true
    ridge.parent = root

    for sideIndex = -1 to 1 by 2 do
    (
        makeBox (prefix + "_Eave") (width + 0.62) 0.16 0.14 [0.0, sideIndex * (length * 0.5 + 0.28), roofBaseZ - 0.02] root matRoof
    )

    makeDoorAndWindows prefix width length wallHeight (plinthHeight + 0.02) root matWood matDark

    for sideIndex = -1 to 1 by 2 do
    (
        makeColumn (prefix + "_VerandaColumn") 0.17 (wallHeight * 0.88) [sideIndex * (width * 0.38), length * 0.5 + 0.78, plinthHeight + wallHeight * 0.44] root matWood
    )

    root.pos = localPosition
    root.rotation.z = rotationZ
    root
)

fn makeHuatai parentNode matStone pebbleCount =
(
    local root = Dummy name:"HakkaWeilongwu_Huatai_ROOT" boxsize:[19.0, 12.0, 1.0]
    root.parent = parentNode

    local centerY = -5.75
    local innerRadius = 2.25
    local outerRadius = 8.35

    local fanVerts = #([0.0, centerY, 0.18])
    local fanFaces = #()
    local fanSegments = 32
    for i = 0 to fanSegments do
    (
        local angle = 180.0 * i / fanSegments
        append fanVerts [cos(angle) * outerRadius, centerY - sin(angle) * outerRadius, 0.18]
        if i > 0 do append fanFaces [1, i + 1, i + 2]
    )
    local huataiFloor = mesh vertices:fanVerts faces:fanFaces name:"HakkaWeilongwu_Huatai_Floor"
    huataiFloor.material = matStone
    huataiFloor.parent = root
    huataiFloor.castShadows = false
    huataiFloor.receiveShadows = true

    for i = 1 to pebbleCount do
    (
        local theta = random 0.0 180.0
        local radius = sqrt (random (innerRadius * innerRadius) (outerRadius * outerRadius))
        local px = cos(theta) * radius
        local py = centerY - sin(theta) * radius
        local pebbleSize = random 0.18 0.34
        local pebble = Sphere radius:pebbleSize segs:6 pos:[px, py, 0.28 + random 0.0 0.10] name:"HakkaWeilongwu_Huatai_Pebble"
        pebble.scale = [random 0.9 1.35, random 0.9 1.35, random 0.45 0.75]
        pebble.material = matStone
        pebble.castShadows = true
        pebble.receiveShadows = true
        pebble.parent = root
    )
    root
)

fn makeRing ringIndex parentNode matWall matRoof =
(
    local radius = if ringIndex == 1 then 11.6 else 15.3
    local height = if ringIndex == 1 then 3.0 else 2.65
    local roofRise = if ringIndex == 1 then 1.02 else 0.88
    local centerY = -5.75
    local segmentCount = if ringIndex == 1 then 18 else 24
    local root = Dummy name:("HakkaWeilongwu_Ring_" + ringIndex as string + "_ROOT") boxsize:[radius * 2.2, radius * 1.2, height + roofRise]
    root.parent = parentNode

    for i = 0 to segmentCount - 1 do
    (
        local theta = 180.0 * (i + 0.5) / segmentCount
        local x = cos(theta) * radius
        local y = centerY - sin(theta) * radius
        local tangentX = -sin(theta)
        local tangentY = -cos(theta)
        local angle = atan2 tangentY tangentX
        local chord = 2.0 * radius * sin(90.0 / segmentCount) + 0.24

        local segmentRoot = Dummy name:("HakkaWeilongwu_Ring_" + ringIndex as string + "_Segment_" + i as string) boxsize:[chord, 2.9, height + roofRise]
        segmentRoot.parent = root

        makeBox "HakkaWeilongwu_Ring_Wall" chord 2.65 height [0.0, 0.0, 0.30 + height * 0.5] segmentRoot matWall
        makeRoof "HakkaWeilongwu_Ring_HardRoof" (chord + 0.38) 3.18 roofRise [0.0, 0.0, 0.30 + height] segmentRoot matRoof false

        segmentRoot.pos = [x, y, 0.0]
        segmentRoot.rotation.z = angle
    )
    root
)

fn makePondMesh parentNode matWater matStone =
(
    local root = Dummy name:"HakkaWeilongwu_FengshuiPond_ROOT" boxsize:[26.0, 14.0, 1.0]
    root.parent = parentNode

    local radius = 9.2
    local centerY = 12.0
    local segments = 36
    local verts = #([0.0, centerY, 0.24])
    local faces = #()
    for i = 0 to segments do
    (
        local angle = 180.0 * i / segments
        append verts [cos(angle) * radius, centerY + sin(angle) * radius, 0.24]
        if i > 0 do append faces [1, i + 1, i + 2]
    )

    local water = mesh vertices:verts faces:faces name:"HakkaWeilongwu_Pond_Water"
    water.material = matWater
    water.castShadows = false
    water.receiveShadows = true
    water.parent = root

    for i = 0 to segments - 1 do
    (
        local a0 = 180.0 * i / segments
        local a1 = 180.0 * (i + 1) / segments
        local midAngle = (a0 + a1) * 0.5
        local x = cos(midAngle) * (radius + 0.16)
        local y = centerY + sin(midAngle) * (radius + 0.16)
        local chord = 2.0 * radius * sin(90.0 / segments) + 0.20
        local rim = makeBox "HakkaWeilongwu_Pond_Rim" chord 0.34 0.25 [x, y, 0.16] root matStone
        rim.rotation.z = midAngle + 90.0
    )
    root
)

fn buildHakkaWeilongwu =
(
    purgePreviousHakkaModel()
    setWaitCursor()

    local ringCount = HAKKA_RING_COUNT
    if ringCount < 1 do ringCount = 1
    if ringCount > 2 do ringCount = 2

    local pebbleCount = HAKKA_HUATAI_PEBBLES
    if pebbleCount < 120 do pebbleCount = 120
    if pebbleCount > 520 do pebbleCount = 520

    local matBrick = makeStandardMaterial "Hakka_GreyWhiteBrick" (color 182 186 178) 12 18 100
    local matBrickDark = makeStandardMaterial "Hakka_GreyBrickDark" (color 132 141 138) 10 16 100
    local matRoof = makeStandardMaterial "Hakka_RoofTile" (color 61 70 76) 18 24 100
    local matWood = makeStandardMaterial "Hakka_Wood" (color 112 67 39) 28 32 100
    local matStone = makeStandardMaterial "Hakka_Cobblestone" (color 170 166 151) 8 12 100
    local matDark = makeStandardMaterial "Hakka_Opening" (color 22 22 20) 5 8 100
    local matWater = makeStandardMaterial "Hakka_FengshuiWater" (color 70 132 146) 68 74 68
    matWater.opacity = 68
    matWater.twoSided = true

    local root = Dummy name:"HakkaWeilongwu_ROOT" boxsize:[42.0, 42.0, 14.0]
    local foundation = makeBox "HakkaWeilongwu_Foundation" 30.5 29.0 0.34 [0.0, -2.4, 0.17] root matStone

    makeBox "HakkaWeilongwu_AxisPath" 2.55 19.5 0.16 [0.0, -1.1, 0.38] root matStone
    makeBox "HakkaWeilongwu_Courtyard_Lower" 6.1 4.1 0.15 [0.0, 3.0, 0.40] root matStone
    makeBox "HakkaWeilongwu_Courtyard_Middle" 6.7 4.5 0.15 [0.0, -2.8, 0.40] root matStone

    local lowerHall = makeGableBuilding "HakkaWeilongwu_LowerHall" [0.0, 7.1, 0.0] 0.0 10.8 3.8 3.25 1.22 root matBrick matRoof matWood matDark
    local middleHall = makeGableBuilding "HakkaWeilongwu_MiddleHall" [0.0, 0.6, 0.0] 0.0 12.2 4.4 4.0 1.48 root matBrickDark matRoof matWood matDark
    local upperHall = makeGableBuilding "HakkaWeilongwu_UpperHall" [0.0, -6.2, 0.0] 0.0 13.6 5.2 4.75 1.72 root matBrickDark matRoof matWood matDark

    local wingLength = 13.8
    local wingDepth = 3.15
    local leftWing = makeGableBuilding "HakkaWeilongwu_LeftWing" [-8.9, -0.6, 0.0] 90.0 wingLength wingDepth 3.12 1.05 root matBrick matRoof matWood matDark
    local rightWing = makeGableBuilding "HakkaWeilongwu_RightWing" [8.9, -0.6, 0.0] 90.0 wingLength wingDepth 3.12 1.05 root matBrick matRoof matWood matDark

    for xIndex = -1 to 1 by 2 do
    (
        makeBox "HakkaWeilongwu_AxisColumnBase" 0.72 0.72 0.22 [xIndex * 4.85, 8.9, 0.13] root matStone
        makeColumn "HakkaWeilongwu_AxisColumn" 0.21 4.45 [xIndex * 4.85, 8.9, 2.34] root matWood
    )

    makeHuatai root matStone pebbleCount
    for ringIndex = 1 to ringCount do makeRing ringIndex root matBrick matRoof
    makePondMesh root matWater matStone

    local frontStep1 = makeBox "HakkaWeilongwu_FrontStep_1" 8.5 1.5 0.24 [0.0, 10.6, 0.12] root matStone
    local frontStep2 = makeBox "HakkaWeilongwu_FrontStep_2" 6.8 1.25 0.24 [0.0, 9.45, 0.36] root matStone

    select root
    max views redraw
    setArrowCursor()

    format "Hakka Weilongwu generated successfully.\n"
    format "Rings: % | Huatai pebbles: %\n" ringCount pebbleCount
    format "Export workflow: File > Export > Export Selected... > glTF Binary (*.glb)\n"
    format "Place the GLB in the web project's ./models/ folder.\n"
)

undo "Generate Hakka Weilongwu" on
(
    with redraw off
    (
        buildHakkaWeilongwu()
    )
)
