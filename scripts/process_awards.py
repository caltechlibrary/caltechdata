import csv
import pandas as pd
from urllib.parse import quote      # URL encoding
import requests

ror_url = 'https://api.ror.org/organizations?query=' 
ror_file = 'ror_mapping.csv'
ror_mapping = {}

with open(ror_file,'r') as csvfile:
    reader = csv.reader(csvfile)
    for row in reader:
        ror_mapping[row[0]] = row[1]

with open(ror_file,'a',newline='') as csvfile:
    writer = csv.writer(csvfile)

    df = pd.read_excel("ct_awards.xlsx")
    federal = df[df['OSR Lvl 4'].str.startswith('Fed')]
    print('Total federal awards: ', len(federal))
    agencies = federal[pd.isnull(federal['Prime Funding Source'])]['Oracle Funding Source Name']
    sub_agencies = federal[pd.notnull(federal['Prime Funding Source'])]['Prime Funding Source']
    agencies = pd.concat([agencies,sub_agencies])
    print('Total agencies: ', len(agencies))
    agencies = pd.unique(agencies)
    for agency in agencies:
        if agency not in ror_mapping:
            print(agency)
            response = requests.get(ror_url+ quote(agency.encode('utf-8')))
            if response.status_code == 200:
                top = response.json()['items'][0]
                print(top)
                inputv = input("Do you approve this ROR?  Type y to approve: ")
                if inputv == "y":
                    writer.writerow([agency,top['id']])
                else:
                    writer.writerow([agency])
            else:
                writer.writerow([agency])
