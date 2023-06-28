import requests
import os, argparse

parser = argparse.ArgumentParser(description="Add user to community")
parser.add_argument("user", help="user id")
parser.add_argument("community", help="community id")


args = parser.parse_args()

# Get access token as environment variable
token = os.environ["RDMTOK"]

url = "https://data.caltech.edu/api/communities/"

headers = {
    "Authorization": "Bearer %s" % token,
    "Content-type": "application/json",
}

data = {"members":[{"id":args.user,"type":"user"}],"role":"manager","message":"<p>Welcome</p>"}


url = url+args.community+'/invitations'

response = requests.post(url,json=data, headers=headers)
if response.status_code != 204:
    print(response.text)
    exit()
