import csv, json
import pandas as pd
from urllib.parse import quote  # URL encoding
import requests

ror_url = "https://api.ror.org/organizations?query="
ror_file = "ror_mapping.csv"
ror_mapping = {}

with open(ror_file, "r") as csvfile:
    reader = csv.reader(csvfile)
    for row in reader:
        ror_mapping[row[0]] = row[1]

with open(ror_file, "a", newline="") as csvfile:
    writer = csv.writer(csvfile)

    df = pd.read_excel("ct_awards.xlsx")
    federal = df[df["OSR Lvl 4"].str.startswith("Fed")]
    print("Total federal awards: ", len(federal))
    agencies = federal[pd.isnull(federal["Prime Funding Source"])][
        "Oracle Funding Source Name"
    ]
    sub_agencies = federal[pd.notnull(federal["Prime Funding Source"])][
        "Prime Funding Source"
    ]
    agencies = pd.concat([agencies, sub_agencies])
    print("Total agencies: ", len(agencies))
    agencies = pd.unique(agencies)
    for agency in agencies:
        if agency not in ror_mapping:
            print(agency)
            response = requests.get(ror_url + quote(agency.encode("utf-8")))
            if response.status_code == 200:
                top = response.json()["items"][0]
                print(top)
                inputv = input("Do you approve this ROR?  Type y to approve: ")
                if inputv == "y":
                    writer.writerow([agency, top["id"]])
                else:
                    writer.writerow([agency])
            else:
                writer.writerow([agency])

federal = federal[[
    "Funding Src Award #",
    "Oracle Funding Source Name",
    "Award #",
    "Prime Funding Source",
    "Prime Agreement #",
    "Award Full Name",]
]

federal = federal.drop_duplicates(subset=['Award #']).set_index("Award #").to_dict('index')

vocabulary = []

for awardn in federal:
    award = federal[awardn]
    formatted = {}
    formatted['id'] = awardn
    formatted['title'] = {'en':str(award['Award Full Name'])}
    if type(award['Prime Agreement #']) == float: #'nan' value
        number = award['Funding Src Award #']
        name = award['Oracle Funding Source Name']
    else:
        number = award['Prime Agreement #']
        name = award["Prime Funding Source"]
    if type(name) == float:
        print(award)
    formatted['number'] = str(number)
    if name in ror_mapping:
        formatted['funder'] = {"id":ror_mapping[name].split('ror.org/')[1]}
        vocabulary.append(formatted)
    else:
        print('SKIPPING DUE TO MISSING GRANT NUMBER', award)

with open('award_vocabulary.json','w') as outfile:
    json.dump(vocabulary,outfile)
