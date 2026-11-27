# Hosting and Network

## Where your pods run

Under Settings → Hosting you choose where Modlight may create pods:

- **Anywhere:** any RunPod data center. The widest choice of cards.
- **EU only:** data centers in the EU, currently in Romania, Sweden, the Netherlands, Czechia and France.
- **EU and EEA:** Iceland and Norway as well.
- **Secure Cloud only:** certified data centers instead of community hosts. RunPod names SOC 2, ISO 27001 and PCI DSS. Usually somewhat more expensive.

With "EU only" or "EU and EEA" Modlight uses Secure Cloud only: community hosts report no location, so it could not be checked.

RunPod treats requested data centers as a preference only. Modlight therefore checks where each pod actually landed. If it is outside, Modlight deletes it straight away, before it answers anything, and tells you.

For the GDPR, RunPod offers a data processing agreement with standard contractual clauses (runpod.io/legal/data-processing-agreement). It does not guarantee a fixed data location. Whether that is enough for your use is yours to judge.

## Access from the local network

Under Settings → Network you choose who may connect:

- **Only this Mac:** the default. Only programs on this Mac reach Modlight.
- **This Mac and the local network:** other computers on the same network can use your models too. "Connection" then shows the address with your Mac's name (`<name>.local`) and its IP.

Requests from the network need your Modlight key as well, and Modlight slows down wrong keys. The connection on the local network is not encrypted, though. Switch it on only in networks you trust, not in public Wi-Fi. The first time, macOS may ask whether Modlight may accept incoming connections.
