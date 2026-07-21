
Set-Location "C:\Users\seankelley\OneDrive - Microsoft\Documents\VISA\PBI - Embedded"

$vs  = 'https://developer.microsoft.com/json-schemas/fabric/item/report/definition/visualContainer/1.5.0/schema.json'
$pageSchema = 'https://developer.microsoft.com/json-schemas/fabric/item/report/definition/page/2.1.0/schema.json'
$metaSchema = 'https://developer.microsoft.com/json-schemas/fabric/item/report/definition/pagesMetadata/1.0.0/schema.json'
$base = 'Commercial_Spend_Analytics.Report\definition\pages'
$fcs  = 'fact_commercialspend'
$ffs  = 'fact_filtersession'

function Wv($pageId, $visId, $content) {
    $dir = "$base\$pageId\visuals\$visId"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Set-Content -Path "$dir\visual.json" -Value $content -Encoding UTF8
}

function Wp($pageId, $content) {
    $dir = "$base\$pageId"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Set-Content -Path "$dir\page.json" -Value $content -Encoding UTF8
}

function mkPage($id, $displayName) {
    return @"
{
  "`$schema": "$pageSchema",
  "name": "$id",
  "displayName": "$displayName",
  "displayOption": "FitToPage",
  "height": 720,
  "width": 1280
}
"@
}

function mkCard($n, $x, $y, $w, $h, $t, $ent, $prop) {
    return @"
{
  "`$schema": "$vs",
  "name": "$n",
  "position": {"x": $x, "y": $y, "z": 0, "width": $w, "height": $h, "tabOrder": $t},
  "visual": {
    "visualType": "card",
    "query": {
      "queryState": {
        "Values": {"projections": [{"field": {"Measure": {"Expression": {"SourceRef": {"Entity": "$ent"}}, "Property": "$prop"}}, "queryRef": "$ent.$prop"}]}
      }
    }
  },
  "filterConfig": {"filters": []}
}
"@
}

function mkCardCount($n, $x, $y, $w, $h, $t, $ent, $prop) {
    return @"
{
  "`$schema": "$vs",
  "name": "$n",
  "position": {"x": $x, "y": $y, "z": 0, "width": $w, "height": $h, "tabOrder": $t},
  "visual": {
    "visualType": "card",
    "query": {
      "queryState": {
        "Y": {"projections": [{"field": {"Aggregation": {"Function": 5, "Expression": {"Column": {"Expression": {"SourceRef": {"Entity": "$ent"}}, "Property": "$prop"}}}}, "queryRef": "Count($ent.$prop)"}]}
      }
    }
  },
  "filterConfig": {"filters": []}
}
"@
}

function mkCol($n, $x, $y, $w, $h, $t, $catEnt, $catProp, $valEnt, $valProp) {
    return @"
{
  "`$schema": "$vs",
  "name": "$n",
  "position": {"x": $x, "y": $y, "z": 0, "width": $w, "height": $h, "tabOrder": $t},
  "visual": {
    "visualType": "clusteredColumnChart",
    "query": {
      "queryState": {
        "X": {"projections": [{"field": {"Column": {"Expression": {"SourceRef": {"Entity": "$catEnt"}}, "Property": "$catProp"}}, "queryRef": "$catEnt.$catProp"}]},
        "Y": {"projections": [{"field": {"Measure": {"Expression": {"SourceRef": {"Entity": "$valEnt"}}, "Property": "$valProp"}}, "queryRef": "$valEnt.$valProp"}]}
      },
      "sortDefinition": {"sort": [{"field": {"Measure": {"Expression": {"SourceRef": {"Entity": "$valEnt"}}, "Property": "$valProp"}}, "direction": "Descending"}], "isDefaultSort": false}
    }
  },
  "filterConfig": {"filters": []}
}
"@
}

function mkColCount($n, $x, $y, $w, $h, $t, $catEnt, $catProp, $cntEnt, $cntProp) {
    return @"
{
  "`$schema": "$vs",
  "name": "$n",
  "position": {"x": $x, "y": $y, "z": 0, "width": $w, "height": $h, "tabOrder": $t},
  "visual": {
    "visualType": "clusteredColumnChart",
    "query": {
      "queryState": {
        "X": {"projections": [{"field": {"Column": {"Expression": {"SourceRef": {"Entity": "$catEnt"}}, "Property": "$catProp"}}, "queryRef": "$catEnt.$catProp"}]},
        "Y": {"projections": [{"field": {"Aggregation": {"Function": 5, "Expression": {"Column": {"Expression": {"SourceRef": {"Entity": "$cntEnt"}}, "Property": "$cntProp"}}}}, "queryRef": "Count($cntEnt.$cntProp)"}]}
      }
    }
  },
  "filterConfig": {"filters": []}
}
"@
}

function mkLine2($n, $x, $y, $w, $h, $t, $axEnt, $axProp, $m1Ent, $m1Prop, $m2Ent, $m2Prop) {
    return @"
{
  "`$schema": "$vs",
  "name": "$n",
  "position": {"x": $x, "y": $y, "z": 0, "width": $w, "height": $h, "tabOrder": $t},
  "visual": {
    "visualType": "lineChart",
    "query": {
      "queryState": {
        "Axis": {"projections": [{"field": {"Column": {"Expression": {"SourceRef": {"Entity": "$axEnt"}}, "Property": "$axProp"}}, "queryRef": "$axEnt.$axProp"}]},
        "Y": {"projections": [
          {"field": {"Measure": {"Expression": {"SourceRef": {"Entity": "$m1Ent"}}, "Property": "$m1Prop"}}, "queryRef": "$m1Ent.$m1Prop"},
          {"field": {"Measure": {"Expression": {"SourceRef": {"Entity": "$m2Ent"}}, "Property": "$m2Prop"}}, "queryRef": "$m2Ent.$m2Prop"}
        ]}
      },
      "sortDefinition": {"sort": [{"field": {"Column": {"Expression": {"SourceRef": {"Entity": "$axEnt"}}, "Property": "$axProp"}}, "direction": "Ascending"}], "isDefaultSort": false}
    }
  },
  "filterConfig": {"filters": []}
}
"@
}

function mkDonut($n, $x, $y, $w, $h, $t, $catEnt, $catProp, $valEnt, $valProp) {
    return @"
{
  "`$schema": "$vs",
  "name": "$n",
  "position": {"x": $x, "y": $y, "z": 0, "width": $w, "height": $h, "tabOrder": $t},
  "visual": {
    "visualType": "donutChart",
    "query": {
      "queryState": {
        "Category": {"projections": [{"field": {"Column": {"Expression": {"SourceRef": {"Entity": "$catEnt"}}, "Property": "$catProp"}}, "queryRef": "$catEnt.$catProp"}]},
        "Y": {"projections": [{"field": {"Measure": {"Expression": {"SourceRef": {"Entity": "$valEnt"}}, "Property": "$valProp"}}, "queryRef": "$valEnt.$valProp"}]}
      }
    }
  },
  "filterConfig": {"filters": []}
}
"@
}

# ==========================================
# PAGE 3: Executive Summary
# ==========================================
Write-Host "Creating Page 3: Executive Summary..."
$p = 'e0e1e2e3e4e5e6e7e8e9'
Wp $p (mkPage $p "Executive Summary")
Wv $p "v_exec01" (mkCard     "v_exec01" 20  20  220 90  1000  $fcs "Total Spend USD")
Wv $p "v_exec02" (mkCard     "v_exec02" 260 20  220 90  2000  $fcs "Transaction Count")
Wv $p "v_exec03" (mkCard     "v_exec03" 500 20  220 90  3000  $fcs "Average Ticket USD")
Wv $p "v_exec04" (mkCard     "v_exec04" 740 20  220 90  4000  $fcs "Approval Rate")
Wv $p "v_exec05" (mkCard     "v_exec05" 980 20  280 90  5000  $fcs "Spend YoY %")
Wv $p "v_exec06" (mkLine2    "v_exec06" 20  130 620 260 6000  "dim_date"    "Year"        $fcs "Total Spend USD"       $fcs "Transaction Count")
Wv $p "v_exec07" (mkDonut    "v_exec07" 660 130 360 260 7000  "dim_segment" "SegmentName" $fcs "Total Spend USD")
Wv $p "v_exec08" (mkCard     "v_exec08" 1040 130 220 120 8000 $fcs "Interchange Revenue USD")
Wv $p "v_exec09" (mkCard     "v_exec09" 1040 270 220 120 9000 $fcs "Fraud Exposure Score")
Wv $p "v_exec10" (mkCol      "v_exec10" 20  410 600 290 10000 "dim_client"  "ClientName"  $fcs "Total Spend USD")
Wv $p "v_exec11" (mkCol      "v_exec11" 640 410 620 290 11000 "dim_product" "ProductName" $fcs "Total Spend USD")
Write-Host "  Page 3 done (11 visuals)"

# ==========================================
# PAGE 4: Supplier Analysis
# ==========================================
Write-Host "Creating Page 4: Supplier Analysis..."
$p = 'b0b1b2b3b4b5b6b7b8b9'
Wp $p (mkPage $p "Supplier Analysis")
Wv $p "v_supl01" (mkCard  "v_supl01" 20  20  380 90  1000 $fcs "Total Spend USD")
Wv $p "v_supl02" (mkCard  "v_supl02" 420 20  380 90  2000 $fcs "Transaction Count")
Wv $p "v_supl03" (mkCard  "v_supl03" 820 20  440 90  3000 $fcs "Average Ticket USD")
Wv $p "v_supl04" (mkCol   "v_supl04" 20  130 620 260 4000 "dim_merchant" "MerchantName" $fcs "Total Spend USD")
Wv $p "v_supl05" (mkCol   "v_supl05" 660 130 600 260 5000 "dim_mcc"      "MCCGroup"     $fcs "Total Spend USD")
Wv $p "v_supl06" (mkCol   "v_supl06" 20  410 620 290 6000 "dim_merchant" "MerchantName" $fcs "Transaction Count")
Wv $p "v_supl07" (mkDonut "v_supl07" 660 410 600 290 7000 "dim_mcc"      "MCCGroup"     $fcs "Transaction Count")
Write-Host "  Page 4 done (7 visuals)"

# ==========================================
# PAGE 5: Spend Trends
# ==========================================
Write-Host "Creating Page 5: Spend Trends..."
$p = 'a0a1a2a3a4a5a6a7a8a9'
Wp $p (mkPage $p "Spend Trends")
Wv $p "v_trnd01" (mkCard  "v_trnd01" 20  20  380 90  1000 $fcs "Total Spend USD")
Wv $p "v_trnd02" (mkCard  "v_trnd02" 420 20  380 90  2000 $fcs "Spend YoY %")
Wv $p "v_trnd03" (mkCard  "v_trnd03" 820 20  440 90  3000 $fcs "Transaction Count")
Wv $p "v_trnd04" (mkLine2 "v_trnd04" 20  130 1240 270 4000 "dim_date" "Year" $fcs "Total Spend USD" $fcs "Transaction Count")
Wv $p "v_trnd05" (mkCol   "v_trnd05" 20  420 600 280 5000 "dim_segment" "SegmentName" $fcs "Total Spend USD")
Wv $p "v_trnd06" (mkLine2 "v_trnd06" 640 420 620 280 6000 "dim_date"    "Year"        $fcs "Average Ticket USD" $fcs "Interchange Revenue USD")
Write-Host "  Page 5 done (6 visuals)"

# ==========================================
# PAGE 6: Savings Opportunities
# ==========================================
Write-Host "Creating Page 6: Savings Opportunities..."
$p = 'c0c1c2c3c4c5c6c7c8c9'
Wp $p (mkPage $p "Savings Opportunities")
Wv $p "v_savg01" (mkCard "v_savg01" 20  20  290 90  1000 $fcs "Interchange Revenue USD")
Wv $p "v_savg02" (mkCard "v_savg02" 330 20  290 90  2000 $fcs "Approval Rate")
Wv $p "v_savg03" (mkCard "v_savg03" 640 20  290 90  3000 $fcs "Decline Rate")
Wv $p "v_savg04" (mkCard "v_savg04" 950 20  310 90  4000 $fcs "Average Ticket USD")
Wv $p "v_savg05" (mkCol  "v_savg05" 20  130 600 260 5000 "dim_product"  "ProductName"  $fcs "Interchange Revenue USD")
Wv $p "v_savg06" (mkCol  "v_savg06" 640 130 620 260 6000 "dim_segment"  "SegmentName"  $fcs "Average Ticket USD")
Wv $p "v_savg07" (mkCol  "v_savg07" 20  410 600 290 7000 "dim_mcc"      "MCCGroup"     $fcs "Decline Rate")
Wv $p "v_savg08" (mkCol  "v_savg08" 640 410 620 290 8000 "dim_country"  "Region"       $fcs "Approval Rate")
Write-Host "  Page 6 done (8 visuals)"

# ==========================================
# PAGE 7: Filter Context Analysis
# ==========================================
Write-Host "Creating Page 7: Filter Context Analysis..."
$p = 'd0d1d2d3d4d5d6d7d8d9'
Wp $p (mkPage $p "Filter Context Analysis")
Wv $p "v_fltx01" (mkCardCount "v_fltx01" 20  20  380 90  1000 $ffs "SessionId")
Wv $p "v_fltx02" (mkCard      "v_fltx02" 420 20  380 90  2000 $fcs "Total Spend USD")
Wv $p "v_fltx03" (mkCard      "v_fltx03" 820 20  440 90  3000 $fcs "Transaction Count")
Wv $p "v_fltx04" (mkColCount  "v_fltx04" 20  130 600 260 4000 $ffs "SessionEventType" $ffs "SessionId")
Wv $p "v_fltx05" (mkColCount  "v_fltx05" 640 130 620 260 5000 $ffs "SelectedYear"     $ffs "SessionId")
Wv $p "v_fltx06" (mkColCount  "v_fltx06" 20  410 600 290 6000 $ffs "SelectedSegments" $ffs "SessionId")
Wv $p "v_fltx07" (mkLine2     "v_fltx07" 640 410 620 290 7000 "dim_date" "Year"        $fcs "Total Spend USD" $fcs "Approval Rate")
Write-Host "  Page 7 done (7 visuals)"

# ==========================================
# UPDATE pages.json (7 pages total)
# ==========================================
Write-Host "Updating pages.json..."
Set-Content -Path "$base\pages.json" -Encoding UTF8 -Value @"
{
  "`$schema": "$metaSchema",
  "pageOrder": [
    "a1b2c3d4e5f601234567",
    "c3d4e5f601234567890a",
    "e0e1e2e3e4e5e6e7e8e9",
    "b0b1b2b3b4b5b6b7b8b9",
    "a0a1a2a3a4a5a6a7a8a9",
    "c0c1c2c3c4c5c6c7c8c9",
    "d0d1d2d3d4d5d6d7d8d9"
  ],
  "activePageName": "e0e1e2e3e4e5e6e7e8e9"
}
"@
Write-Host "  pages.json updated (7 pages)"

# ==========================================
# GIT COMMIT + PUSH
# ==========================================
Write-Host "Committing and pushing..."
git add -A
git status --short
git commit -m "feat: add 5 new report pages (Executive Summary, Supplier Analysis, Spend Trends, Savings Opportunities, Filter Context Analysis)"
git push origin branch
Write-Host "All done! Sync Fabric via Source Control -> Update."
