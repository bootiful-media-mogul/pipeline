// answers every request with a redirect to TARGET, keeping the path and the query: the bare
// domain (mogul.tools) is not an app of its own, so it sends people to the studio.
package main

import (
	"log"
	"net/http"
	"os"
	"strings"
)

func main() {
	target := strings.TrimSuffix(os.Getenv("TARGET"), "/")
	if target == "" {
		log.Fatal("TARGET is not set")
	}
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target+r.URL.RequestURI(), http.StatusFound)
	})
	log.Fatal(http.ListenAndServe(":"+os.Getenv("PORT"), nil))
}
