import requests
import os, argparse
from caltechdata_api import caltechdata_edit

def grid_to_ror(grid):
    # We manually handle some incorrect/redundant GRID Ids
    if grid == "grid.451078.f":
        ror = "https://ror.org/00hm6j694"
    elif grid == 'grid.5805.8':
        ror = "https://ror.org/02en5vm52"
    else:
        url = f"https://api.ror.org/organizations?query.advanced=external_ids.GRID.all:{grid}"
        results = requests.get(url)
        ror = results.json()["items"][0]["id"]
    return ror

parser = argparse.ArgumentParser(description="Fix DOI for stuck record")
parser.add_argument("ids", nargs="*", help="CaltechDATA IDs to fix")

args = parser.parse_args()

# Get access token as environment variable
token = os.environ["RDMTOK"]

url = "https://data.caltech.edu/api/records"

headers = {
    "Authorization": "Bearer %s" % token,
    "accept": "application/vnd.datacite.datacite+json",
}

for idv in args.ids:
    response = requests.get(f"{url}/{idv}", headers=headers)
    metadata = response.json()
    #Fix incorrect GRID export for funders
    if 'fundingReferences' in metadata:
        for funder in metadata['fundingReferences']:
            if 'funderIdentifier' in funder:
                funder['funderIdentifier'] = grid_to_ror(funder['funderIdentifier'])
                funder['funderIdentifierType'] = 'ROR'
    caltechdata_edit(idv,metadata,production=True,publish=True)
